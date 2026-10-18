#include "thirdparty/scd30/sensirion_i2c_hal.h"
// #include "mock_sensiron_i2c_hal.h"
#include <stdio.h>

#define NOT_IMPLEMENTED_ERROR 31

bool g_mock_sensirion_i2c_hal_initialized = false;

int16_t sensirion_i2c_hal_select_bus(uint8_t bus_idx) {
    printf("[mock] sensirion_i2c_hal_select_bus called");
    return NOT_IMPLEMENTED_ERROR;
}
void sensirion_i2c_hal_init(void) {
    g_mock_sensirion_i2c_hal_initialized = true;
    printf("[mock] sensirion_i2c_hal_init called\n");
}
void sensirion_i2c_hal_free(void) {
    printf("[mock] sensirion_i2c_hal_free called\n");
}

int8_t sensirion_i2c_hal_read(uint8_t address, uint8_t* data, uint8_t count) {
    printf("[mock] sensirion_i2c_hal_read called\n");
    return NOT_IMPLEMENTED_ERROR;
}
int8_t sensirion_i2c_hal_write(uint8_t address, const uint8_t* data,
                               uint8_t count) {
    printf("[mock] sensirion_i2c_hal_write called\n");
    return NOT_IMPLEMENTED_ERROR;
}

void sensirion_i2c_hal_sleep_usec(uint32_t useconds) {
    printf("[mock] sensirion_i2c_hal_sleep_usec called\n");
}
