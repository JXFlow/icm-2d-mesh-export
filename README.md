# ICM 2D Mesh Results Exporter
Export per-element **Max(Depth × Speed)** hazard results from InfoWorks ICM 2D simulations to CSV — with timestep tracking for peak values.
## The Problem
InfoWorks ICM does not provide a direct way to export per-element 2D mesh results (like flood hazard = Depth × Velocity) across all timesteps. The Ruby API does not expose individual 2D mesh elements as iterable objects, and bulk GIS exports can consume hundreds of gigabytes of disk space.
## The Solution
A two-stage Ruby script that:
1. **Runs inside ICM** (`export_2d_mesh.rb`) — prompts for options and generates parallel worker scripts, a merge script and a launcher.
2. **Runs via IcmExchange** (`launch_parallel.bat`) — processes all timestep chunks, checks worker completion and merges validated maxima.
### How It Works
```
For each timestep (0 → N):
  1. Export 2D element results to temporary .mif/.mid files
  2. Parse the .mif header to dynamically map column names → indices
  3. Read the .mid data file to extract Depth and Speed per element
  4. Calculate DxV = Depth × Speed × Multiplier (in Ruby)
  5. Update in-memory maximums if current values exceed stored values
  6. Delete temporary files immediately
  7. Move to next timestep
Merge validated chunks into <Simulation Name>_Hazard Mapping.csv
```
This keeps temporary GIS disk usage to approximately one timestep per worker, regardless of simulation length.
## Output
### `<Simulation Name>_Hazard Mapping.csv`
| Column | Description |
|---|---|
| `Element_ID` | 2D mesh element number |
| `Max_DxV` | Maximum Depth × Speed (hazard) across all timesteps |
| `Max_Depth` | Maximum depth recorded (independent of DxV) |
| `Max_Speed` | Maximum speed recorded (independent of DxV) |
| `Step_Index_Max_DxV` | Timestep index when Max_DxV occurred |
| `Step_Index_Max_Depth` | Timestep index when Max_Depth occurred |
| `Step_Index_Max_Speed` | Timestep index when Max_Speed occurred |
### `Max_Hazard_Category`
| Category | ARR 2019 Vulnerability Classification | Limits (Exceeding these limits upgrades to next category) |
|---|---|---|
| 1 | Generally safe for vehicles, people and buildings | D*V ≤ 0.3, Depth ≤ 0.3m, Velocity ≤ 2.0m/s |
| 2 | Unsafe for small vehicles | D*V ≤ 0.6, Depth ≤ 0.5m, Velocity ≤ 2.0m/s |
| 3 | Unsafe for vehicles, children and the elderly | D*V ≤ 0.6, Depth ≤ 1.2m, Velocity ≤ 2.0m/s |
| 4 | Unsafe for vehicles and people | D*V ≤ 1.0, Depth ≤ 2.0m, Velocity ≤ 2.0m/s |
| 5 | Unsafe for vehicles and people. Vulnerable to structural damage | D*V ≤ 4.0, Depth ≤ 4.0m, Velocity ≤ 4.0m/s |
| 6 | Unsafe for vehicles and people. Considered vulnerable to failure | D*V > 4.0 |
*(Note: A minimum "wet/dry" filter of depth ≥ 0.01m is applied to ignore numerical noise. Dry elements default to Category 1).*
## Usage
### Parallel export (`export_2d_mesh.rb`)
Splits the export across multiple simultaneous `IcmExchange.exe` processes for significantly faster processing.
> **Note:** Each parallel worker consumes one ICM license. Running 4 workers = 4 concurrent licenses.
#### Architecture
```
ICM UI (export_2d_mesh.rb)
  ├── Resolves Run ID → GUID
  ├── Generates worker_c0.rb ... worker_cN.rb (one per core)
  ├── Generates merge_workers.rb
  └── Generates launch_parallel.bat
launch_parallel.bat
  ├── Launches N × IcmExchange.exe workers (minimized to taskbar)
  ├── Each worker: loops its timestep chunk (process-and-delete)
  ├── Each worker: validates total timesteps and every MIF/MID result
  ├── Each worker: writes worker_X_done.txt only after its CSV is closed
  ├── Worker windows auto-close when finished
  ├── Polls every 5s for errors and process exits, with a finite wait limit
  ├── Runs merge_workers.rb → <Simulation Name>_Hazard Mapping.csv
  └── Publishes the final CSV only after every chunk passes validation
```
#### Step 1: Run the Generator
Open `export_2d_mesh.rb` inside InfoWorks ICM. The dialog prompts for:
| Option | Description | Default |
|---|---|---|
| **Run ID** | The simulation Run ID | — |
| **Database Path** | Path to ICM database | Auto-detected |
| **Output Folder** | Parent directory for a fresh `mesh_export_...` subfolder | `D:\Temp` |
| **Multiplier** | DxV scale factor | `1.0` |
| **Keep Timestep CSVs?** | Save per-step CSVs | `false` |
| **Number of Parallel Workers** | How many IcmExchange processes to spawn | `4` |
| **IcmExchange.exe Path** | Full path to IcmExchange executable; adjust for your installation | ICM Ultimate 2026 installation path |
A second dialog asks for a positive whole-number **total timestep count** because this workflow reads simulation timesteps through IcmExchange. Every worker compares this count with `list_timesteps.count` before exporting. Both underestimates and overestimates fail with the actual count in the error log; regenerate the scripts with that count. Counts are not silently clamped.
#### Step 2: Launch the Batch File
Open the new subfolder shown by the generator and double-click `launch_parallel.bat`. Worker processes run **minimized in the taskbar**. The launcher checks every worker's error log before waiting for pending workers. A process wrapper detects unsuccessful exits and exits without a completion record, including failures before Ruby starts. The merge starts only after every process has exited and every worker has a success record.
#### Step 3: Collect Results
The final CSV is named `<Simulation Name>_Hazard Mapping.csv` in the new subfolder. Use it only when the launcher reports **All done!** and `merge_done.txt` exists without an error log. The merge checks contiguous timestep coverage, expected row counts, matching element IDs, numeric values and CSV headers. It writes a `.partial` file and renames it only after a successful write. Scripts, chunk CSVs and logs are retained for diagnosis; temporary MIF/MID files are still deleted after each successful timestep.

#### Failure handling and scope
- Missing, empty, malformed or multiple MIF/MID outputs fail explicitly. This exporter supports one MIF/MID pair per timestep; multi-file exports require separate support rather than silently selecting the first file.
- Element IDs must be unique and the same across timesteps and workers. This catches missing rows relative to the first export, but does not independently verify that ICM exported every element of the original mesh.
- The default worker wait limit is 24 hours. For a longer legitimate export, edit `set max_polls=17280` in the generated launcher before its first use (each poll waits five seconds; for example, `34560` is approximately 48 hours).
- On failure, inspect `worker_N_error.log`, `worker_N_console.log` or `merge_error.log`. Partial timestep/chunk CSVs are diagnostic only. Other workers may still be running; stop them before removing files. Regenerate into a fresh subfolder to retry. A generated launcher is single-use, which prevents stale success files from satisfying a rerun.
- The wait limit covers the parallel workers; the final IcmExchange merge invocation remains synchronous. The changes do not alter hazard formulas, timestep partitioning or the GIS export API.

## Validation
Run the offline regression suite with a Ruby installation that provides `csv`:
```text
ruby -c export_2d_mesh.rb
ruby test/reliability_test.rb
```
The suite executes generated scripts against a fake ICM API and simulated worker files. It covers count mismatches, missing/malformed exports, worker exceptions, incomplete chunks and known maxima. On Windows it also exercises the batch launcher with Ruby standing in for IcmExchange, including native-style failure exits, absent status files, timeout, merge failure and stale-run refusal. No ICM installation or database is used by these tests.

Before operational use, validate in your installed ICM version against a small, known simulation:
1. Export with the exact timestep count using one worker and then multiple workers. Compare all element IDs, maxima and timestep indices, including the final timestep, against a trusted reference.
2. Enter one fewer and one extra timestep. Confirm an explicit count-mismatch error, no merge and no final CSV.
3. Try an invalid IcmExchange path and interrupt one worker. Confirm failure is reported and no incomplete final CSV is published.
4. Confirm the actual MIF schema, element coverage and zero/dry values match the assumptions above. The offline tests do not establish live ICM compatibility or hydraulic correctness.
## Files
| File | Purpose |
|---|---|
| `export_2d_mesh.rb` | Parallel generator script (run inside ICM; use one worker for serial execution) |
| `test/reliability_test.rb`, `test/fake_icm.rb` | Offline regression tests and simulated ICM API |
| `ICM_Scripting_Learnings.md` | Technical learnings and API gotchas documented during development |
## Requirements
- **InfoWorks ICM** (2024 or later, with IcmExchange)
- A completed 2D simulation with results
- Windows OS
- **Parallel mode:** One ICM license per concurrent worker
## Key Learnings
These patterns were discovered during development and may help others working with ICM scripting:
1. **Collections ≠ Arrays** — `WSModelObjectCollection` does not support `.find` or `.select`. Use `.each` loops instead.
2. **Run ≠ Simulation** — A Run ID may point to a container. Always check for child `Sim` objects.
3. **SQL in exports is unreliable for 2D** — Calculated fields (like `tsr.depth2d * tsr.speed2d`) can silently return zeros. Perform calculations in Ruby instead.
4. **Never hardcode column indices** — Parse the `.mif` header dynamically to map column names to positions.
5. **Iterate, don't batch** — Exporting all timesteps at once can consume hundreds of GB. Process one step at a time and delete immediately.
6. **UI vs IcmExchange** — `WSApplication.current_database` in the UI cannot access simulation result timesteps. Only `WSApplication.open()` via IcmExchange can call `list_timesteps`.
7. **Avoid nested heredocs** — Generating Ruby scripts that themselves generate Ruby scripts using heredocs causes uncontrollable string interpolation bugs. Use `lines << "..."` arrays instead.
See [`ICM_Scripting_Learnings.md`](ICM_Scripting_Learnings.md) for the full write-up.
## License
MIT
