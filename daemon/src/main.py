from db import save_measurement
import db
from hardware.scd30 import SCD30
import time
import argparse

CYCLE_TIME_S = 5

def main(db_path: str):
    sensors = [SCD30()]

    db.connect(db_path)
    
    db.migrate()

    while True:
        cycle_start_time_ns = time.time_ns()    

        measurements = {}
        for sensor in sensors:
            sensor_measurements = sensor.get_measurements()
            measurements.update(sensor_measurements)
        
        print(measurements)
        save_measurement(measurements)
        cycle_end_time_ns = time.time_ns()
        time.sleep(max(0, CYCLE_TIME_S - (cycle_end_time_ns - cycle_start_time_ns) / 1e9))  
    
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run the daemon.")
    parser.add_argument("db",nargs="?", type=str, default="db.sqlite", help="Path to the SQLite database file.")
    args = parser.parse_args()
    main(args.db)