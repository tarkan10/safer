# Ada Critical System Simulator

A real-time system simulation written in Ada, demonstrating binary packet parsing, state machine validation, protected queues, concurrent tasks, and deadline monitoring.

## Features

- Binary packet parsing and validation
- State machine with validated transitions
- Thread-safe queue using protected objects
- Concurrent producer and processor tasks
- Deadline monitoring with `Ada.Real_Time`
- Exception handling and controlled shutdown

## Requirements

- GNAT Ada compiler

Install dependencies:

```bash
sudo apt update
sudo apt install gnat gprbuild

## Windows Installation

1. Install [MSYS2](https://www.msys2.org/).
2. Open **MSYS2 UCRT64** from the Start menu.
3. Update the package database
