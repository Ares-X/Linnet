-- Test-only positive fixture for the shipped-Lua offline scanner.
os.execute("offline-scanner-probe")
require("socket.http")
