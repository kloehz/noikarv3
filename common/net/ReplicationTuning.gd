extends RefCounted

## Measurement-only tuning of Netfox's public setting, not an authority or
## payload change. Baseline leaves authored values untouched. ACK traffic must
## be counted before claiming savings. Vendored tick > next makes N+1 ticks.
func apply_profile(sync: StateSynchronizer, profile: String, native_hz: int, diffs_enabled: bool) -> bool:
	if profile == "" or profile == "baseline":
		return true
	if profile != "diff_ack_100ms" or native_hz not in [30, 60] or not diffs_enabled:
		return false
	sync.diff_ack_interval = ceili(float(native_hz) * 0.1) - 1
	return true
