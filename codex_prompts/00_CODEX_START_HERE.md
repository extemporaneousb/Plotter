# Codex start prompt: plotter control/calibration workstream

You are Codex working inside a repository that will become a Mac-local control and calibration system for one physical machine: a 2-axis servo pen plotter driven by an OpenBuilds BlackBox X32 controller running grblHAL-compatible firmware.

The first goal is not a polished app. The first goal is to de-risk the controller connection, discover the actual firmware/controller behavior, and build a safe control/calibration foundation.

Read and follow these files in order:

1. `01_SUPERVISOR_PROMPT.md`
2. `04_PROJECT_CONTRACT.md`
3. `03_PHASE_GATES_AND_ACCEPTANCE.md`
4. `02_WORKER_PROMPTS.md`
5. `05_HANDOFF_TEMPLATE.md`

Operate as a supervisor coordinating workers. If your environment supports multiple agents, assign one worker per role in `02_WORKER_PROMPTS.md`. If not, execute the workers sequentially, preserving their boundaries and handoff notes.

Hard constraints:

- Default to no-motion and dry-run behavior.
- Do not send machine-motion commands unless an explicit armed flag is required and checked.
- Do not assume homing is configured correctly.
- Do not assume pen servo commands are known.
- Do not write GRBL/grblHAL settings (`$NN=value`) in early phases.
- Use USB serial first because the machine is physically connected by cable now.
- Design for possible future Wi-Fi transport, but do not implement Wi-Fi until the USB transport and controller behavior are observed.
- Do not implement vector-graphics import in phase 1.
- Build one core package with multiple entrypoints, not disconnected programs.
- Keep the controller/calibration core independent of the eventual UI technology.

Output required from the first Codex run:

1. A repository plan and staged task list.
2. A minimal but runnable first implementation focused on controller interrogation.
3. Tests for parsing and safety gates.
4. A README explaining how to probe the controller safely.
5. A clear handoff note identifying what still needs real-hardware transcript data.

Do not ask broad questions before starting. Use sensible defaults and record assumptions. Ask only narrow blocking questions.
