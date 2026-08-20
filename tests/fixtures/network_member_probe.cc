// Static negative fixture: neither member selector is the POSIX network
// function. This file is inspected but never compiled or shipped.
void inspect_member_connects(auto& notifier, auto* pointer) {
  notifier.connect();
  pointer->connect();
}
