import argparse
from cffi import FFI
import os
import textwrap
cdef = """
    int16_t scd30_blocking_read_measurement_data(float* co2_concentration,
                                            float* temperature,
                                            float* humidity);
                                            
    void sensirion_i2c_hal_init(void);
    int16_t scd30_start_periodic_measurement(uint16_t ambient_pressure);
    void scd30_init(uint8_t i2c_address);
    """
real_sources = {
    "thirdparty/scd30/": [
        "sensirion_common.c",
        "sensirion_i2c.c",
        "scd30_i2c.c",
       	"sensirion_i2c_hal.c",
    ],
}
mock_sources = {
    "mock/": [
        "mock_scd30_i2c.c",
        "mock_sensirion_i2c_hal.c",
    ],
}

defs = '''
    #include "thirdparty/scd30/scd30_i2c.h"
    #include "thirdparty/scd30/sensirion_i2c_hal.h"
    '''


here = os.path.dirname(os.path.abspath(__file__))
sources_dir = os.path.join(here, "native")
build_dir = os.path.join(here, "build")

def generate_src_list(mock=False):
    directories = mock_sources if mock else real_sources
    return [os.path.join(sources_dir, dir_path, f) for dir_path, files in directories.items() for f in files]

def build_native(mock=False):
    if mock:
        print("Using mock implementations.")
    ffibuilder = FFI()
    
    ffibuilder.cdef(cdef)

    ffibuilder.set_source(
        "native_cffi",                 
        defs,    
        sources=generate_src_list(mock=mock),
        include_dirs=[sources_dir,os.path.join(sources_dir, "thirdparty/scd30")],             # Look in the current directory for headers
    )
    ffibuilder.compile(verbose=True,tmpdir= build_dir) 
def write_pyproject_file():
    pyproject_content = '''\
        [project]
        name = "native_cffi"
        version = "0.1.0"
        dependencies = []

        [tool.setuptools]
        py-modules = ["native_cffi"]
        '''
    with open(build_dir + "/pyproject.toml", "w") as f:
        f.write(textwrap.dedent(pyproject_content))
    
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Build the native C extension.")
    parser.add_argument("--mock", action="store_true", help="Use mock implementation.")
    args = parser.parse_args()
    build_native(mock=args.mock)
    write_pyproject_file()

