from native_cffi import ffi, lib


hal_started = False

def hal_init():
    global hal_started
    if not hal_started:
        lib.sensirion_i2c_hal_init()
        hal_started = True
