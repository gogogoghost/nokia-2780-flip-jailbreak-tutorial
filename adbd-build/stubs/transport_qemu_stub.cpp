// Stub: device has no goldfish (emulator) pipe support.
#include "transport.h"
bool use_qemu_goldfish() { return false; }
void qemu_socket_thread(int port) { (void)port; }
