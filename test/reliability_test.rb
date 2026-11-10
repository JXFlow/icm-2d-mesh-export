# Run with plain Ruby: ruby test/reliability_test.rb
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'csv'
require_relative '../export_2d_mesh'

RUBY = RbConfig.ruby
FAKE = File.expand_path('fake_icm.rb', __dir__)
HEADER = 'Element_ID,Max_DxV,Max_Depth,Max_Speed,Step_Index_Max_DxV,Step_Index_Max_Depth,Step_Index_Max_Speed,Max_Hazard_Category'

def assert(condition, message)
  raise message unless condition
end

def worker(folder, index: 0, first: 0, last: 1, count: 2)
  path = File.join(folder, "worker_c#{index}.rb")
  write_worker_script(path, core_idx: index, start_idx: first, end_idx: last,
    expected_count: count, safe_db: "fake database's path", safe_out: folder,
    resolved_id: '{1234-abcd}', mult_str: '1.0', keep_csv: false)
  path
end

def execute(path, mode = 'ok', steps = 2)
  Open3.capture2e({'FAKE_CASE' => mode, 'FAKE_STEPS' => steps.to_s}, RUBY, '-r', FAKE, path)
end

def merge(folder, workers = 1, count = 2)
  path = File.join(folder, 'merge_workers.rb')
  write_merge_script(path, folder, workers, "Test's simulation", count)
  path
end

def final_path(folder)
  File.join(folder, "Test's simulation_Hazard Mapping.csv")
end

tests = {}
tests['worker success and known maxima'] = proc do |dir|
  output, status = execute(worker(dir))
  assert(status.success?, output)
  assert(File.read(File.join(dir, 'worker_0_done.txt')) == '0,1,2,2', 'Wrong completion record')
  output, status = execute(merge(dir))
  assert(status.success?, output)
  data = CSV.read(final_path(dir), headers: true)
  assert(data[0]['Max_DxV'] == '4.0' && data[0]['Step_Index_Max_DxV'] == '1', 'Wrong maxima')
  assert(File.exist?(File.join(dir, 'merge_done.txt')), 'Missing merge success')
  assert(!File.exist?(final_path(dir) + '.partial'), 'Partial file left after success')
end

{'underestimated count' => 3, 'overestimated count' => 1, 'zero actual timesteps' => 0}.each do |name, actual|
  tests[name] = proc do |dir|
    output, status = execute(worker(dir), 'ok', actual)
    assert(!status.success? && output.include?('Timestep count mismatch'), output)
    assert(!File.exist?(File.join(dir, 'worker_0_done.txt')), 'False success')
    assert(!Dir.exist?(File.join(dir, 'temp_calc_0')), 'Export started before count validation')
  end
end

%w[exception missing_target missing_mif multiple_mif missing_mid missing_column empty_mid bad_number infinite_number short_row duplicate_id missing_element changed_element].each do |mode|
  tests["worker rejects #{mode}"] = proc do |dir|
    output, status = execute(worker(dir), mode)
    assert(!status.success?, output)
    assert(File.exist?(File.join(dir, 'worker_0_error.log')), 'Missing worker error')
    assert(!File.exist?(File.join(dir, 'worker_0_done.txt')), 'False worker success')
    output, status = execute(merge(dir))
    assert(!status.success? && !File.exist?(final_path(dir)), output)
  end
end

def simulate_chunks(dir)
  2.times do |i|
    File.write(File.join(dir, "worker_#{i}_done.txt"), "#{i},#{i},2,2")
    File.write(File.join(dir, "worker_#{i}_max.csv"), "#{HEADER}\n1,#{i + 1},1,1,#{i},#{i},#{i},1\n2,0,0,0,#{i},#{i},#{i},1\n")
  end
end

mutations = {
  'valid parallel chunks' => proc { |_| },
  'missing chunk' => proc { |d| File.delete(File.join(d, 'worker_1_max.csv')) },
  'missing completion' => proc { |d| File.delete(File.join(d, 'worker_1_done.txt')) },
  'error alongside completion' => proc { |d| File.write(File.join(d, 'worker_1_error.log'), 'failed') },
  'empty chunk' => proc { |d| File.write(File.join(d, 'worker_1_max.csv'), '') },
  'truncated chunk' => proc { |d| p = File.join(d, 'worker_1_max.csv'); File.write(p, File.readlines(p)[0..1].join) },
  'malformed row' => proc { |d| File.open(File.join(d, 'worker_1_max.csv'), 'a') { |f| f.puts 'broken' } },
  'coverage gap' => proc { |d| File.write(File.join(d, 'worker_1_done.txt'), '2,2,3,2') },
  'different element set' => proc { |d| p = File.join(d, 'worker_1_max.csv'); File.write(p, File.read(p).sub("\n2,", "\n3,")) }
}
mutations.each do |name, mutate|
  tests["merge: #{name}"] = proc do |dir|
    simulate_chunks(dir)
    mutate.call(dir)
    output, status = execute(merge(dir, 2))
    success = name == 'valid parallel chunks'
    assert(status.success? == success, output)
    assert(File.exist?(final_path(dir)) == success, 'Final CSV publication incorrect')
    assert(File.exist?(File.join(dir, 'merge_done.txt')) == success, 'Merge status incorrect')
    assert(File.exist?(File.join(dir, 'worker_0_max.csv')), 'Lost diagnostic chunk')
  end
end

if Gem.win_platform?
  %w[ok exception crash no_status timeout merge_failure reused].each do |mode|
    tests["Windows launcher: #{mode}"] = proc do |dir|
      workers = [worker(dir, first: 0, last: 0), worker(dir, index: 1, first: 1, last: 1)]
      merge_path = merge(dir, 2)
      File.write(merge_path, "exit(0)\n") if mode == 'merge_failure'
      launcher = File.join(dir, 'launch_parallel.bat')
      write_launch_bat(launcher, RUBY, workers, merge_path)
      # Keep tests windowless and fast; run the generated control flow with real cmd.exe.
      text = File.read(launcher).gsub('start /MIN', 'start /B').gsub(/^pause\r?$/, 'rem pause')
      # Windows timeout.exe cannot wait on redirected stdin (Open3 uses pipes).
      text = text.gsub('timeout /t 5 /nobreak >nul', "\"#{RUBY}\" -e \"sleep 0.05\"")
      text = text.sub('set max_polls=17280', "set max_polls=#{mode == 'timeout' ? 1 : 100}")
      text = text.gsub(/^start \/B.*$/, 'rem simulate a worker that never starts') if mode == 'timeout'
      File.write(launcher, text)
      Dir.mkdir(File.join(dir, 'launch_started')) if mode == 'reused'
      env = {'RUBYOPT' => '-rfake_icm', 'RUBYLIB' => __dir__, 'FAKE_CASE' => mode}
      output, status = Timeout.timeout(30) { Open3.capture2e(env, 'cmd.exe', '/d', '/c', 'launch_parallel.bat', chdir: dir) }
      success = mode == 'ok'
      assert(status.success? == success, output)
      assert(output.include?('All done!') == success, output)
      assert(File.exist?(final_path(dir)) == success, 'Unexpected final CSV')
      assert(output.include?('EXPORT FAILED') != success, output)
      if %w[exception crash no_status].include?(mode)
        error = File.read(File.join(dir, 'worker_0_error.log'))
        expected = mode == 'exception' ? 'Simulated database failure' : 'Worker exited without successful completion'
        assert(error.include?(expected), error)
      elsif mode == 'merge_failure'
        assert(File.exist?(File.join(dir, 'worker_0_done.txt')), 'Workers did not succeed before merge failure')
      end
    end
  end
else
  puts 'SKIP: Windows batch integration tests (requires Windows)'
end

failed = 0
tests.each do |name, test|
  # Include spaces, apostrophes, ampersands and parentheses in generated paths.
  Dir.mktmpdir('mesh_test_') do |root|
    dir = File.join(root, "results & (test's)")
    Dir.mkdir(dir)
    begin
      test.call(dir.tr('\\', '/'))
      puts "PASS: #{name}"
    rescue => e
      failed += 1
      warn "FAIL: #{name}: #{e.message}"
      Dir.glob(File.join(dir, '*log')).each { |path| warn "#{File.basename(path)}: #{File.read(path)}" }
    end
  end
end
puts "#{tests.size} tests, #{failed} failures"
exit(failed.zero? ? 0 : 1)
