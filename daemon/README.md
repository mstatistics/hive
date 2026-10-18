# Hive Daemon
A python and c background process that ingests readings from sensors and controls actuators. Communication is done through a sqlite database from the webserver

## Development

### Run daemon 
```bash
# default to ./db.sqlite
uv run ./src/main.py
# Specify a db location
uv run ./src/main.py ../db.sqlite
```
The C bindings may need to be built for this to function
### Native C code
Some sensors prefer interfacing with their c driver directly. These drivers live in `/native/thirdparty`. Mock implementations live in `/native/mock`. To build the c code and python bindings, run
```bash
# Build for real hardware
uv run ./build_native.py 
# Build mock for testing
uv run ./build_native.py --mock
```
New bindings can be created by updating `build_native.py` with the new function definitions, source files, mock files, and headers.
## Development UI
This project ships with [datasette](https://datasette.io/), a web-based sql viewer. To run a development server, run
```bash
# Allow only from localhost
datasette ./db.sqlite
# Allow access outside of localhost. Be careful
datasette ./db.sqlite -h 0.0.0.0
```