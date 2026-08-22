// Stubs for functions not needed in this adbd build.
#include <string>
#include <string_view>

std::string UsbNoPermissionsLongHelpText() { return "no permissions"; }
std::string UsbNoPermissionsShortHelpText() { return "no permissions"; }

// abb (shell bridge) service is not used.
struct atransport;
int execute_abb_command(std::string_view name) { (void)name; return -1; }
