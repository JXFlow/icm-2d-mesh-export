# Export 2D Mesh Generator (Bypasses UI Lock)
# ============================================
# FINAL VERSION + TIME INDICES (ALL)
# - FEATURE: Adds 'Step_Index_Max_Depth' and 'Step_Index_Max_Speed'.
# - FEATURE: 'Keep Timestep CSVs?' option (Default: False).
# - LOGIC: Calculates DxV in Ruby.
# - FIX: Replaces .find on Collection with .each loop.
# - FIX: Reverts to Checkbox for options.
# - FIX: Unifies logic for Check/Run modes.

require 'date'

def generate_export_scripts
  puts "=" * 60
  puts "2D Mesh Export - Batch Script Generator"
  puts "=" * 60

  # Get Database Path
  db_path = ""
  begin
    db = WSApplication.current_database
    db_path = db.path 
  rescue
    db_path = "\\\\localhost\\MASTER_DB" 
  end

  # Prompt 
  prompts_safe = [
    ['Run ID (GUID/Int)', 'String', ''],
    ['Database Path', 'String', db_path],
    ['Output Folder', 'String', 'D:\\Temp', nil, 'FOLDER', 'Select Output Folder'],
    ['Multiplier', 'String', '1.0'],
    ['Check Columns Only?', 'Boolean', false],
    ['Keep Timestep CSVs?', 'Boolean', false]
  ]
  
  res = WSApplication.prompt("Export Options (All Time Indices)", prompts_safe, false)
  return if res.nil?
  
  run_id    = res[0].strip
  db_path   = res[1].strip
  out_folder= res[2]
  mult_str  = res[3]
  check_col = res[4] # Boolean
  keep_csv  = res[5] # Boolean

  if run_id.empty?
    puts "Error: Run ID required."
    return
  end
  
  # --- Generate the Worker Ruby Script ---
  safe_out = out_folder.gsub('\\', '/')
  safe_db  = db_path.gsub('\\', '/')
  
  worker_script = <<~RUBY
    require 'date'
    require 'fileutils'
    
    begin
      puts "Connecting to database..."
      db = WSApplication.open('#{safe_db}', false)
      
      target = nil
      run_id = '#{run_id}'
      target = db.model_object(run_id) rescue nil
      
      if target.nil? && run_id.match?(/^\\d+$/)
         ['Sim', 'Run'].each do |t|
           target = db.model_object_from_type_and_id(t, run_id.to_i) rescue nil
           break if target
         end
      end
      
      if target.nil?
         def find_recursive(parent, id_str)
            return parent if parent.id.to_s == id_str
            if parent.respond_to?(:children)
               parent.children.each do |c|
                  found = find_recursive(c, id_str)
                  return found if found
               end
            end
            nil
         end
         db.root_model_objects.each do |r|
            target = find_recursive(r, run_id)
            break if target
         end
      end
      
      if target.nil?
        puts "ERROR: Could not find Run with ID: \#{run_id}"
        exit(1)
      end
      
      puts "Found Object: \#{target.name} (Type: \#{target.type rescue 'Unknown'})"
      
      if !target.respond_to?(:list_timesteps)
         if target.respond_to?(:children)
            sim_child = nil
            target.children.each do |c|
               if c.type == 'Sim'
                  sim_child = c
                  break
               end
            end
            if sim_child
               puts "Found Simulation: \#{sim_child.name}"
               target = sim_child
            else
               puts "FATAL ERROR: Object is not a Simulation and contains no Sims!"
               exit(1)
            end
         else
            puts "FATAL ERROR: Object is not a Simulation!"
            exit(1)
         end
      end

      steps = target.list_timesteps
      if steps.respond_to?(:to_a)
         steps = steps.to_a
      end
      
      count = steps.count
      puts "Timesteps: \#{count}"
      
      folder = '#{safe_out}'
      temp_folder = File.join(folder, "temp_calc_loop")
      Dir.mkdir(temp_folder) unless Dir.exist?(temp_folder)
      
      mult_val = #{mult_str}.to_f
      keep_csvs = #{keep_csv}
      
      params = {
        'Tables' => ['_2DElements'],
        '2DZoneSQL' => [
            ['Depth', 'depth2d', 4],
            ['Speed', 'speed2d', 4]
        ],
        'ExportMaxima' => false,
        'AlternativeNaming' => false 
      }
      
      check_mode = #{check_col}
      
      if check_mode
         start_idx = 140
         end_idx   = 140 
         puts "-- CHECK COLUMNS MODE (Step 140) --"
      else
         start_idx = 0
         end_idx   = count - 1 
         puts "-- RUN EXPORT MODE (FULL: 0 to \#{end_idx}) --"
      end
      
      # Data Structure: [Max_DxV, Max_Depth, Max_Speed, T_DxV, T_Depth, T_Speed]
      max_data = {} 
      
      (start_idx..end_idx).each do |idx|
        if idx % 10 == 0 || idx == start_idx
           puts "-- Processing Step \#{idx} / \#{end_idx} --"
        end
        
        target.results_GIS_export('MIF', idx, params, temp_folder)
        
        mif_files = Dir.glob(File.join(temp_folder, "**", "*.[mM][iI][fF]"))
        if mif_files.empty?
           puts "   WARNING: No MIF file created at step \#{idx}!" if check_mode
           next
        end
        mif_file = mif_files.first
        
        col_map = {}
        in_columns = false
        col_index = 0
        File.foreach(mif_file) do |line|
           line.strip!
           if line.match(/^Columns\\s+(\\d+)/i)
              in_columns = true; next
           end
           if in_columns
              break if line.match(/^Data/i)
              parts = line.split(' ')
              if parts.size >= 2
                 col_name = parts[0].gsub('"', '')
                 col_map[col_name] = col_index
                 col_index += 1
              end
           end
        end
        
        if check_mode
           puts "   Columns found: \#{col_map.keys.join(', ')}"
           puts "\\n=== AVAILABLE COLUMNS ==="
           col_map.each do |name, i|
              puts "  Index \#{i}: \#{name}"
           end
           puts "=========================\\n"
           
           Dir.glob(File.join(temp_folder, "**", "*")).each { |f| File.delete(f) rescue nil }
           Dir.glob(File.join(temp_folder, "**", "*")).select { |d| File.directory?(d) }.each { |d| Dir.rmdir(d) rescue nil }
           Dir.rmdir(temp_folder) rescue nil
           exit(0)
        end

        idx_depth = col_map.keys.find { |k| k.upcase.include?('DEPTH') || k.upcase == 'DEPTH2D' }
        idx_speed = col_map.keys.find { |k| k.upcase.include?('SPEED') || k.upcase == 'SPEED2D' }
        
        i_depth = col_map[idx_depth] rescue -1
        i_speed = col_map[idx_speed] rescue -1
        
        dirname  = File.dirname(mif_file)
        basename = File.basename(mif_file, ".*") 
        mid_pattern = File.join(dirname, "\#{basename}.[mM][iI][dD]")
        mid_candidates = Dir.glob(mid_pattern)
        if mid_candidates.empty?
           mid_candidates = [
              File.join(dirname, "\#{basename}.mid"),
              File.join(dirname, "\#{basename}.MID")
           ].select { |f| File.exist?(f) }
        end
        next if mid_candidates.empty?
        mid_file = mid_candidates.first
        
        csv_handle = nil
        if keep_csvs
            step_csv_path = File.join(folder, "Step_\#{idx}.csv")
            csv_handle = File.open(step_csv_path, 'w')
            csv_handle.puts "Element_ID,DxV,Depth,Speed"
        end
        
        File.foreach(mid_file) do |line|
            parts = line.strip.split(',')
            next if parts.size < 4
            id = parts[1].gsub('"', '').strip 
            vals = parts.map { |v| v.to_f }
            
            dep = (i_depth >= 0) ? vals[i_depth] : 0.0
            s   = (i_speed >= 0) ? vals[i_speed] : 0.0
            d_calc = dep * s * mult_val
            
            if csv_handle
               csv_handle.puts "\#{id},\#{d_calc},\#{dep},\#{s}"
            end
            
            # Update Max (In-Memory)
            # Structure: [DxV, Depth, Speed, T_DxV, T_Depth, T_Speed]
            if max_data[id].nil?
              max_data[id] = [d_calc, dep, s, idx, idx, idx]
            else
              cur = max_data[id]
              
              # Max DxV
              if d_calc > cur[0]
                 cur[0] = d_calc
                 cur[3] = idx
              end
              
              # Max Depth (Independent)
              if dep > cur[1]
                 cur[1] = dep
                 cur[4] = idx
              end
              
              # Max Speed (Independent)
              if s > cur[2]
                 cur[2] = s
                 cur[5] = idx
              end
              
              max_data[id] = cur
            end
        end
        
        csv_handle.close if csv_handle
        
        mif_files.each { |f| File.delete(f) rescue nil }
        mid_candidates.each { |f| File.delete(f) rescue nil }
        Dir.glob(File.join(temp_folder, "*")).select { |d| File.directory?(d) }.each { |d| Dir.rmdir(d) rescue nil }
      end
      
      Dir.rmdir(temp_folder) rescue nil
      
      max_csv_path = File.join(folder, "Max_DxV_Final.csv")
      puts "Writing Final MAX CSV: \#{max_csv_path}"
      File.open(max_csv_path, 'w') do |csv|
        csv.puts "Element_ID,Max_DxV,Max_Depth,Max_Speed,Step_Index_Max_DxV,Step_Index_Max_Depth,Step_Index_Max_Speed"
        max_data.each do |id, vals|
          csv.puts "\#{id},\#{vals[0]},\#{vals[1]},\#{vals[2]},\#{vals[3]},\#{vals[4]},\#{vals[5]}"
        end
      end
      puts "Done!"
      
    rescue => e
      puts "FATAL ERROR: \#{e.message}"
      puts e.backtrace
    end
  RUBY

  # Write .rb file
  rb_file = File.join(out_folder, "worker_export.rb")
  File.write(rb_file, worker_script)
  puts "Generated Script: #{rb_file}"

  # --- Generate the Batch File ---
  
  icm_path = "C:\\Program Files\\Autodesk\\InfoWorks ICM Ultimate 2026.2\\IcmExchange.exe"
  
  [
     "C:\\Program Files\\Autodesk\\InfoWorks ICM Ultimate 2026.2\\IcmExchange.exe",
     "C:\\Program Files\\Autodesk\\InfoWorks ICM Ultimate 2026.1\\IcmExchange.exe",
     "C:\\Program Files\\Autodesk\\InfoWorks ICM Ultimate 2026\\IcmExchange.exe",
     "C:\\Program Files\\Innovyze Workgroup Client 2026.2\\IcmExchange.exe"
  ].each do |p|
    if File.exist?(p)
      icm_path = p
      break
    end
  end
  
  bat_content = <<~BAT
    @echo off
    set ICM_CMD="#{icm_path}"
    set SCRIPT="#{rb_file.gsub('/', '\\')}"
    
    echo Running Tool (All Max Timesteps)...
    %ICM_CMD% %SCRIPT% /nogui
    
    echo.
    echo Done.
    pause
  BAT

  bat_file = File.join(out_folder, "run_export.bat")
  File.write(bat_file, bat_content)
  puts "Generated Batch: #{bat_file}"
  
  WSApplication.message_box("Please run the generated .bat file.", "OK", nil, false)
end

generate_export_scripts
