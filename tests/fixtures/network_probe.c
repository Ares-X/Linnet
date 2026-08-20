#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>

// These disabled lines are static probes for the framework and remote-launch
// rules. They never enter the compiled fixture.
#if 0
#import <Network/Network.h>
NSWorkspace.shared.open(URL(string: "https://network-probe.invalid")!)
#endif

static const char *network_entitlement_probe =
    "com.apple.security.network.client";

int main(void) {
  struct addrinfo hints = {0};
  struct addrinfo *addresses = NULL;
  hints.ai_socktype = SOCK_STREAM;

  int result = getaddrinfo("127.0.0.1", "9", &hints, &addresses);
  int descriptor = socket(AF_INET, SOCK_STREAM, 0);
  if (descriptor >= 0 && addresses != NULL) {
    result += connect(descriptor, addresses->ai_addr,
                      addresses->ai_addrlen);
  }
  if (descriptor >= 0) {
    close(descriptor);
  }
  if (addresses != NULL) {
    freeaddrinfo(addresses);
  }
  return network_entitlement_probe[0] == '\0' ? result : 0;
}
