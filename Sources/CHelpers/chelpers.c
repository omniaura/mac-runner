#include "chelpers.h"
#include <stdlib.h>

int run_system_command(const char *command) {
    return system(command);
}
