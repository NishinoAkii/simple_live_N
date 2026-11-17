#ifndef RUNNER_D3D_GUARD_H_
#define RUNNER_D3D_GUARD_H_

// Turns on Direct3D 11 multithread protection for the device Flutter creates.
// Call once at startup, before the Flutter engine is created. The reason and
// the way it works are described in d3d_guard.cpp.
void InstallD3DGuard();

#endif  // RUNNER_D3D_GUARD_H_
