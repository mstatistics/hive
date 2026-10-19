from native_cffi import ffi, lib
from hardware.hal import hal_init
from sensor import Sensor
class SCD30(Sensor):
    def __init__(self):
        hal_init()
        lib.scd30_init(0x61)
        lib.scd30_start_periodic_measurement(0)  # Start periodic measurement with ambient pressure = 0 (no compensation)
    def blocking_read_measurement_data(self):
        co2_concentration = ffi.new("float *")
        temperature = ffi.new("float *")
        humidity = ffi.new("float *")
        err = lib.scd30_blocking_read_measurement_data(co2_concentration, temperature, humidity)
        if err != 0:
            raise RuntimeError("Failed to read SCD30 measurement data: error code {}".format(err))
        return co2_concentration[0], temperature[0], humidity[0]
    def get_measurements(self) -> dict[str, float]:
        co2_concentration, temperature, humidity = self.blocking_read_measurement_data()
        return {
            "co2": co2_concentration,
            "c_temp": temperature,
            "RH": humidity
        }
