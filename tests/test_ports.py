"""Check port detection against real Linux sockets, including minimal systems."""
import pathlib
import socket
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "xray-ss.sh"
CHECK = r'''
source "$1"
CONFIG="$2/config.json"
test_tools="$5"
command() {
  if [[ "$1" == -v && ( "${2:-}" == ss || "${2:-}" == netstat ) ]]; then
    if [[ "$test_tools" == broken-ss && "${2:-}" == ss ]]; then return 0; fi
    return 1
  fi
  builtin command "$@"
}
ss() { return 1; }
"$3" "$4"
'''


@unittest.skipUnless(sys.platform.startswith("linux"), "requires /proc/net on Linux")
class PortDetectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def check_port(self, function, port, expected, tools="missing"):
        result = subprocess.run(
            ["bash", "-c", CHECK, "port-test",
             str(SCRIPT), self.directory.name, function, str(port), tools],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, expected, result.stderr)

    def test_tcp_listener_without_ss_or_netstat(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            port = listener.getsockname()[1]
            self.check_port("port_in_use", port, 0)
            self.check_port("tcp_port_is_listening", port, 0)

    def test_bound_udp_port_is_reserved_but_is_not_a_tcp_listener(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as bound:
            bound.bind(("127.0.0.1", 0))
            port = bound.getsockname()[1]
            self.check_port("port_in_use", port, 0)
            self.check_port("tcp_port_is_listening", port, 1)

    def test_closed_port_is_available(self):
        with socket.socket() as bound:
            bound.bind(("127.0.0.1", 0))
            port = bound.getsockname()[1]
        self.check_port("port_in_use", port, 1)
        self.check_port("tcp_port_is_listening", port, 1)

    def test_failed_ss_command_falls_back_to_proc(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            self.check_port("tcp_port_is_listening", listener.getsockname()[1],
                            0, tools="broken-ss")

    def test_ipv6_listener_without_network_tools(self):
        try:
            listener = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            self.addCleanup(listener.close)
            listener.bind(("::1", 0))
        except OSError as error:
            self.skipTest(str(error))
        listener.listen()
        port = listener.getsockname()[1]
        self.check_port("port_in_use", port, 0)
        self.check_port("tcp_port_is_listening", port, 0)


if __name__ == "__main__":
    unittest.main()
