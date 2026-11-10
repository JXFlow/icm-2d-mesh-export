# Simulated IcmExchange API; never opens a database.
module WSApplication
  def self.open(*)
    exit!(17) if ENV['FAKE_CASE'] == 'crash'
    exit(0) if ENV['FAKE_CASE'] == 'no_status'
    raise 'Simulated database failure' if ENV['FAKE_CASE'] == 'exception'
    self
  end

  def self.model_object(*)
    ENV['FAKE_CASE'] == 'missing_target' ? nil : self
  end

  def self.model_object_from_type_and_id(*)
    model_object
  end

  def self.name; 'Test simulation'; end
  def self.type; 'Sim'; end
  def self.list_timesteps; Array.new(Integer(ENV.fetch('FAKE_STEPS', '2')), 0); end

  def self.results_GIS_export(format, idx, params, folder)
    raise 'Unexpected export API arguments' unless format == 'MIF' && params['Tables'] == ['_2DElements']
    mode = ENV['FAKE_CASE']
    return if mode == 'missing_mif'
    columns = ['Zone Char(20)', 'Element_ID Integer', 'Depth Float', 'Speed Float']
    columns[2] = 'Wrong Float' if mode == 'missing_column'
    File.write(File.join(folder, 'mesh.mif'), "Columns 4\n#{columns.join("\n")}\nData\n")
    File.write(File.join(folder, 'extra.mif'), 'extra') if mode == 'multiple_mif'
    return if mode == 'missing_mid'
    rows = ["\"zone, one\",1,#{idx + 1},2", 'zone,2,0,0']
    rows = [] if mode == 'empty_mid'
    rows[0] = 'zone,1,bad,2' if mode == 'bad_number'
    rows[0] = 'zone,1,1e999,2' if mode == 'infinite_number'
    rows[0] = 'zone,1' if mode == 'short_row'
    rows << rows.first if mode == 'duplicate_id'
    rows.pop if mode == 'missing_element' && idx == 1
    rows[1] = 'zone,3,0,0' if mode == 'changed_element' && idx == 1
    File.write(File.join(folder, 'mesh.mid'), rows.join("\n") + (rows.empty? ? '' : "\n"))
  end
end
