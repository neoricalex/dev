#include <config.h>
#include <stdio.h>
#include <stdlib.h>

int main (int argc, char *argv[]) {
  // Create a new application
  puts ("Hello World!");
  puts ("This is " PACKAGE_STRING ".");
  int shell=system("cd src/virtualhost && bash iniciar.sh");

  return 0;
}