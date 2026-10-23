#!/usr/bin/env python3
"""Execute the pinned upstream send-flag function to check Netfox's lossy contract.

This is a source-level compatibility characterization, NOT a binary/P2P test.
It compiles the unmodified upstream method in a minimal C++ harness. The normal
offline suite does not fetch source or silently bless this known-red gate.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

SHA256 = "9670cb68c74b5bcaa6391f091074ccfd21a0738d3e7e234c812efdded26b50c2"
TEMP_ROOT = Path("/private/var/folders/kq/sw184q4x2vz7vp4dcxhk4hg40000gn/T/opencode")


def compile_upstream_flags(source: Path) -> list[int]:
    data = source.read_bytes()
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError("Expected exact GodotSteam v4.23.1 source; SHA256 mismatch")
    text = data.decode()
    start = text.index("const int SteamMultiplayerPeer::_get_steam_packet_flags()")
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    method = text[start:end]
    # SDK send-flag values, plus only the class surface this method consumes.
    header = r'''
#include <cstdint>
#include <iostream>
#define ERR_FAIL_V_MSG(value, message) return value
constexpr int k_nSteamNetworkingSend_Unreliable = 0;
constexpr int k_nSteamNetworkingSend_NoNagle = 1;
constexpr int k_nSteamNetworkingSend_NoDelay = 4;
constexpr int k_nSteamNetworkingSend_Reliable = 8;
class SteamMultiplayerPeer {
public:
    enum TransferMode { TRANSFER_MODE_UNRELIABLE, TRANSFER_MODE_UNRELIABLE_ORDERED, TRANSFER_MODE_RELIABLE };
    bool no_nagle = false, no_delay = false;
    TransferMode mode = TRANSFER_MODE_UNRELIABLE;
    TransferMode get_transfer_mode() { return mode; }
    const int _get_steam_packet_flags();
};
'''
    main = r'''
int main() {
    SteamMultiplayerPeer peer;
    for (auto mode : {SteamMultiplayerPeer::TRANSFER_MODE_UNRELIABLE,
                     SteamMultiplayerPeer::TRANSFER_MODE_UNRELIABLE_ORDERED,
                     SteamMultiplayerPeer::TRANSFER_MODE_RELIABLE}) {
        peer.mode = mode;
        std::cout << peer._get_steam_packet_flags() << '\n';
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="noikar-steam-contract-", dir=TEMP_ROOT) as tmp:
        path = Path(tmp)
        cpp = path / "contract.cpp"
        binary = path / "contract"
        cpp.write_text(header + method + main)
        subprocess.run(["clang++", "-std=c++17", str(cpp), "-o", str(binary)], check=True, capture_output=True, text=True)
        result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
    return [int(line) for line in result.stdout.splitlines()]


class SteamNetfoxTransferContract(unittest.TestCase):
    flags: list[int]

    def test_reliable_remains_reliable(self):
        self.assertNotEqual(self.flags[2] & 8, 0)

    def test_unreliable_remains_lossy(self):
        self.assertEqual(self.flags[0] & 8, 0)

    def test_ordered_updates_remain_lossy_without_reliable_retransmission(self):
        self.assertEqual(self.flags[1] & 8, 0,
                         "Pinned peer promotes Netfox ordered-unreliable updates to reliable delivery; wire/performance parity is unverified")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Exact upstream v4.23.1 godotsteam_multiplayer_peer.cpp")
    args = parser.parse_args()
    SteamNetfoxTransferContract.flags = compile_upstream_flags(args.source)
    unittest.main(argv=[__file__], verbosity=2)
