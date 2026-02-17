# InfoWorks ICM Scripting: Key Learnings & Patterns
**Subject:** Exporting 2D Mesh Results (Depth, Speed, Hazard)
**Date:** February 2026

## 1. The Core Challenge: 2D Elements
In the ICM Ruby API, **2D Mesh Elements (Triangles)** are not directly accessible as enumerable network objects in the same way strictly defined objects (like Manholes or Pipes) are.
*   **Problem**: You cannot simply do `network.row_objects('_2DElement').each`.
*   **Solution**: You must use **`results_GIS_export`** to dump the data to an intermediate file format (MIF/MID or SHP) and then parse that file to get element-level data.

## 2. API Object Handling
### Collections are not Arrays
The `WSModelObjectCollection` returned by methods like `parent.children` is a C++ wrapper.
*   **Gotcha**: It does **not** support standard Ruby Enumerable methods like `.find`, `.select`, or `.map` directly.
*   **Fix**: Always iterate manually using `.each` or check if `.to_a` is supported before using array methods.

### Runs vs. Simulations
A "Run" ID often points to a **Run Object** (container), not the **Simulation Object** (results).
*   **Pattern**: When given a Run ID, always check if it has children.
    ```ruby
    if target.type == 'Run'
      sim = target.children.find { |c| c.type == 'Sim' } # via .each loop
    end
    ```

## 3. Optimizing for Disk & Memory
### The "All Timesteps" Trap
Exporting all timesteps via `results_GIS_export` without a loop creates a physical file for *every single timestep* immediately. For large 2D meshes, this can generate hundreds of gigabytes of data in minutes, filling the drive.
*   **Pattern: Iterative Process-and-Delete**
    1.  Loop through timesteps in Ruby (`0..count`).
    2.  Export **only one** timestep to a temporary folder.
    3.  Parse the file immediately to extract data/maxima.
    4.  **Delete** the temporary file before moving to the next step.

## 4. Data Calculation: Ruby vs. SQL
### SQL Export Reliability
Using SQL expressions inside `results_GIS_export` (e.g., `tsr.depth2d * tsr.speed2d`) for 2D elements can be unreliable, sometimes returning zeros even when data exists.
*   **Fix**: Export the raw, known-good fields (`Depth2D`, `Speed2D`) and perform the calculation (Hazard = D × V) inside the Ruby script. This is slower but guarantees accuracy.

## 5. File Parsing & Column Mapping
Column orders in exported GIS files (MIF/MID) are not guaranteed to be static.
*   **Pattern**: Never hardcode indices (e.g., `row[3]`).
*   **Fix**: Always parse the header (e.g., `.mif` file) to dynamically map column names to indices.
    ```ruby
    # Example .mif parsing logic
    if line =~ /^Columns (\d+)/ ...
    col_map[column_name] = index
    ```

## 6. User Experience
*   **Prompts**: `WSApplication.prompt` is sensitive. Boolean checkboxes are more stable across API versions than complex dropdown lists.
*   **Feedback**: For batch processes (processing 100+ files), always print "Processing Step X of Y" to the console so the user knows the script hasn't hung.
