# ICM 2D Mesh Results Exporter

Export per-element **Max(Depth × Speed)** hazard results from InfoWorks ICM 2D simulations to CSV — with timestep tracking for peak values.

## The Problem

InfoWorks ICM does not provide a direct way to export per-element 2D mesh results (like flood hazard = Depth × Velocity) across all timesteps. The Ruby API does not expose individual 2D mesh elements as iterable objects, and bulk GIS exports can consume hundreds of gigabytes of disk space.

## The Solution

A two-stage Ruby script that:

1. **Runs inside ICM** (`export_2d_mesh.rb`) — prompts the user for options and generates a worker script + batch file.
2. **Runs via IcmExchange** (`worker_export.rb` + `run_export.bat`) — iterates through every timestep, exports temporary MIF/MID files, parses them, tracks maximums in memory, and cleans up after each step.

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

Write final Max_DxV_Final.csv
```

This keeps disk usage to ~1 timestep at a time, regardless of simulation size.

## Output

### `Max_DxV_Final.csv`

| Column | Description |
|---|---|
| `Element_ID` | 2D mesh element number |
| `Max_DxV` | Maximum Depth × Speed (hazard) across all timesteps |
| `Max_Depth` | Maximum depth recorded (independent of DxV) |
| `Max_Speed` | Maximum speed recorded (independent of DxV) |
| `Step_Index_Max_DxV` | Timestep index when Max_DxV occurred |
| `Step_Index_Max_Depth` | Timestep index when Max_Depth occurred |
| `Step_Index_Max_Speed` | Timestep index when Max_Speed occurred |

## Usage

### Step 1: Run the Generator

Open `export_2d_mesh.rb` as a Ruby script inside InfoWorks ICM. A dialog will prompt for:

| Option | Description | Default |
|---|---|---|
| **Run ID** | The simulation Run ID (GUID or integer) | — |
| **Database Path** | Path to your ICM database | Auto-detected |
| **Output Folder** | Where to save output files | `D:\Temp` |
| **Multiplier** | Scale factor applied to DxV calculation | `1.0` |
| **Check Columns Only?** | If checked, exports one timestep and prints column names to the console for verification | `false` |
| **Keep Timestep CSVs?** | If checked, saves a `Step_X.csv` for every timestep (used for debugging) | `false` |

### Step 2: Run the Batch File

Navigate to your output folder and double-click `run_export.bat`. This launches IcmExchange in headless mode to process all timesteps.

### Step 3: Collect Results

Once complete, `Max_DxV_Final.csv` will be in your output folder.

## Files

| File | Purpose |
|---|---|
| `export_2d_mesh.rb` | Main generator script (run inside ICM) |
| `calc_max_dxv.sql` | ICM SQL stored query for verifying DxV logic on individual elements |
| `diagnose_2d.rb` | Diagnostic script for listing available 2D result tables |
| `diagnose_2d_v2.rb` | Extended diagnostic script with table enumeration |
| `ICM_Scripting_Learnings.md` | Technical learnings and API gotchas documented during development |

## Requirements

- **InfoWorks ICM** (2024 or later, with IcmExchange)
- A completed 2D simulation with results
- Windows OS

## Key Learnings

These patterns were discovered during development and may help others working with ICM scripting:

1. **Collections ≠ Arrays** — `WSModelObjectCollection` does not support `.find` or `.select`. Use `.each` loops instead.
2. **Run ≠ Simulation** — A Run ID may point to a container. Always check for child `Sim` objects.
3. **SQL in exports is unreliable for 2D** — Calculated fields (like `tsr.depth2d * tsr.speed2d`) can silently return zeros. Perform calculations in Ruby instead.
4. **Never hardcode column indices** — Parse the `.mif` header dynamically to map column names to positions.
5. **Iterate, don't batch** — Exporting all timesteps at once can consume hundreds of GB. Process one step at a time and delete immediately.

See [`ICM_Scripting_Learnings.md`](ICM_Scripting_Learnings.md) for the full write-up.

## License

MIT
