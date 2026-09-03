# zmq.mojo — libzmq via runtime dlopen (DLHandle), so NO build-time link flag is
# needed. `mojo build src/main.mojo -o mojoudfclient` — no -Xlinker at all.
#
# Because libzmq is dlopen'd (not a link-time NEEDED entry), it will NOT show up
# in `ldd mojoudfclient`; the container image must stage `libzmq.so.5` (and its
# own dependency closure) explicitly — the Dockerfile does this.
#
# UNVERIFIED Mojo. The C API is standard libzmq (stable since 3.x):
#   void*  zmq_ctx_new(void);
#   void*  zmq_socket(void* ctx, int type);              // ZMQ_REQ = 3
#   int    zmq_setsockopt(void*, int, const void*, size_t);
#   int    zmq_connect(void*, const char*);
#   int    zmq_send(void*, const void*, size_t, int);
#   int    zmq_recv(void*, void*, size_t, int);          // returns msg size
#   int    zmq_close(void*);   int zmq_ctx_term(void*);  int zmq_errno(void);

from sys.ffi import DLHandle
from memory import UnsafePointer

alias c_void = NoneType
alias Ptr = UnsafePointer[c_void]

alias ZMQ_REQ = 3
alias ZMQ_LINGER = 17
alias ZMQ_RCVTIMEO = 27
alias ZMQ_SNDTIMEO = 28
alias EAGAIN = 11

struct ZmqReq:
    var lib: DLHandle          # kept alive for the process → symbols stay valid
    var ctx: Ptr
    var sock: Ptr

    fn __init__(out self, endpoint: String) raises:
        var lib = DLHandle("libzmq.so.5")   # raises if the library is missing

        var ctx = lib.get_function[fn () -> Ptr]("zmq_ctx_new")()
        if not ctx:
            raise Error("zmq_ctx_new failed")
        var socket_fn = lib.get_function[fn (Ptr, Int32) -> Ptr]("zmq_socket")
        var sock = socket_fn(ctx, Int32(ZMQ_REQ))
        if not sock:
            raise Error("zmq_socket failed")

        # Set int options: LINGER=0, RCVTIMEO=1000ms, SNDTIMEO=1000ms.
        var setopt = lib.get_function[
            fn (Ptr, Int32, UnsafePointer[Int32], Int) -> Int32]("zmq_setsockopt")
        var v0 = Int32(0)
        _ = setopt(sock, Int32(ZMQ_LINGER), UnsafePointer(to=v0), 4)
        var v1000 = Int32(1000)
        _ = setopt(sock, Int32(ZMQ_RCVTIMEO), UnsafePointer(to=v1000), 4)
        _ = setopt(sock, Int32(ZMQ_SNDTIMEO), UnsafePointer(to=v1000), 4)

        # zmq_connect wants a NUL-terminated C string.
        var c = endpoint + "\0"
        var rc = lib.get_function[fn (Ptr, UnsafePointer[Int8]) -> Int32](
            "zmq_connect")(sock, c.unsafe_ptr().bitcast[Int8]())
        if rc != 0:
            raise Error("zmq_connect failed for " + endpoint)

        self.lib = lib
        self.ctx = ctx
        self.sock = sock

    fn _errno(self) -> Int32:
        return self.lib.get_function[fn () -> Int32]("zmq_errno")()

    # Send one frame; retry the RCVTIMEO/SNDTIMEO EAGAIN like the reference client
    # (a poll interval, not a deadline). REQ manages the empty delimiter frame.
    fn send(self, data: List[UInt8]) raises:
        var send_fn = self.lib.get_function[
            fn (Ptr, UnsafePointer[UInt8], Int, Int32) -> Int32]("zmq_send")
        while True:
            var rc = send_fn(self.sock, data.unsafe_ptr(), len(data), Int32(0))
            if rc >= 0:
                return
            if self._errno() == EAGAIN:
                continue
            raise Error("zmq_send failed")

    # Receive one frame. libzmq truncates to the buffer but returns the true
    # size, so grow and retry if the message was larger than the buffer.
    fn recv(self) raises -> List[UInt8]:
        var recv_fn = self.lib.get_function[
            fn (Ptr, UnsafePointer[UInt8], Int, Int32) -> Int32]("zmq_recv")
        var cap = 65536
        while True:
            var buf = UnsafePointer[UInt8].alloc(cap)
            var n = recv_fn(self.sock, buf, cap, Int32(0))
            if n < 0:
                buf.free()
                if self._errno() == EAGAIN:
                    continue
                raise Error("zmq_recv failed")
            if Int(n) > cap:
                buf.free()
                cap = Int(n)          # message bigger than buffer → grow, retry
                continue
            var out = List[UInt8]()
            for i in range(Int(n)):
                out.append(buf[i])
            buf.free()
            return out^

    fn close(mut self):
        _ = self.lib.get_function[fn (Ptr) -> Int32]("zmq_close")(self.sock)
        _ = self.lib.get_function[fn (Ptr) -> Int32]("zmq_ctx_term")(self.ctx)
