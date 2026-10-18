#include "thirdparty/scd30/scd30_i2c.h"
#include <stdio.h>
bool periodic_measurement_started = false;
extern bool g_mock_sensirion_i2c_hal_initialized;
int16_t scd30_start_periodic_measurement(uint16_t ambient_pressure) {
    if (!g_mock_sensirion_i2c_hal_initialized) {
        printf("[mock] scd30_start_periodic_measurement called, but HAL not initialized\n");
        return -1; // Return an error code if HAL is not initialized
    }
    if (!periodic_measurement_started) {
        periodic_measurement_started = true;
    } else {
        printf("[mock] scd30_start_periodic_measurement called, but periodic measurement already started\n");
    }
    return 0; // Return 0 to indicate success
}

int16_t scd30_blocking_read_measurement_data(float* co2_concentration,float* temperature,float* humidity) {
    if (!g_mock_sensirion_i2c_hal_initialized) {
        printf("[mock] scd30_blocking_read_measurement_data called, but HAL not initialized\n");
        return -1; // Return an error code if HAL is not initialized
    }
    if (!periodic_measurement_started) {
        printf("[mock] scd30_blocking_read_measurement_data called, but periodic measurement not started\n");
        return -1; // Return an error code if periodic measurement has not been started
    }
    *co2_concentration = 400.0;
    *temperature = 25.0;
    *humidity = 50.0;
    return 0; // Return 0 to indicate success
}