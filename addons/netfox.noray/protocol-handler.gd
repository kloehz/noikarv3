extends RefCounted
class_name NorayProtocolHandler
## This class parses incoming data from noray's protocol.
##
## Unless you're writing your own noray integration, [Noray] should cover most
## use cases.

## Emitted for every command parsed during a [method ingest] call.
signal on_command(command: String, data: String)

var _strbuf: String = ""

## Resets the parser.
func reset():
	_strbuf = ""

## Parse an incoming piece of data.
func ingest(data: String):
	_strbuf += data
	if not _strbuf.contains("\n"):
		return

	var idx = _strbuf.rfind("\n")
	var lines = _strbuf.substr(0, idx).split("\n", false)
	_strbuf = _strbuf.erase(0, idx + 1)

	for line in lines:
		if not line.contains(" "):
			on_command.emit(line, "")
		else:
			# Split off only the command; the rest of the line (which can
			# contain spaces, e.g. `error Failed to provision server`) is
			# the data payload. Older commands like `host-ready <oid>`
			# happen to use the first whitespace-delimited token, which
			# still works since there are no embedded spaces in OIDs.
			var sep_idx := line.find(" ")
			var command := line.substr(0, sep_idx)
			var param := line.substr(sep_idx + 1)
			on_command.emit(command, param)
