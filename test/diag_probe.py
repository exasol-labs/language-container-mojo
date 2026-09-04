#!/usr/bin/env python3
"""Probe for the diagnostic build: drive diag.mojo through handshake + one input
cycle, then decode and print the MT_CLOSE exception_message it sends (the
MOJO-DIAG report). Confirms the diagnostic produces a usable report before it is
deployed to a real Exasol."""
import sys
import zmq
import fake_exasol as F  # reuse the wire helpers

MT_CLOSE = 4

def close_message(buf):
    # envelope field 5 = close(sub); close field 1 = exception_message(string)
    def sub(field_no, start, end):
        for f, w, v in F.walk(buf, start, end):
            if f == field_no and w == 2:
                return v
        return None
    close = sub(5, 0, len(buf))
    if close is None:
        return "(no close field)"
    msg = sub(1, *close)
    if msg is None:
        return "(no exception_message)"
    s, e = msg
    return bytes(buf[s:e]).decode("utf-8", "replace")

def main():
    ctx = zmq.Context()
    sock = ctx.socket(zmq.REP)
    sock.setsockopt(zmq.RCVTIMEO, 10000)
    sock.bind("tcp://127.0.0.1:6583")
    try:
        assert F.msg_type(sock.recv()) == F.MT_CLIENT; sock.send(F.m_info())
        assert F.msg_type(sock.recv()) == F.MT_META;   sock.send(F.m_meta())
        assert F.msg_type(sock.recv()) == F.MT_RUN;    sock.send(F.bare(F.MT_RUN))
        assert F.msg_type(sock.recv()) == F.MT_NEXT;   sock.send(F.m_next([21]))
        got = sock.recv()
    except zmq.Again:
        print("TIMEOUT: diag never reached the CLOSE step", file=sys.stderr)
        return 2
    sock.send(F.bare(F.MT_FINISHED))   # let diag's post-close recv return
    mt = F.msg_type(got)
    if mt != MT_CLOSE:
        print("expected CLOSE(4), diag sent %d" % mt, file=sys.stderr)
        return 3
    print("REPORT: " + close_message(got))
    return 0

if __name__ == "__main__":
    sys.exit(main())
