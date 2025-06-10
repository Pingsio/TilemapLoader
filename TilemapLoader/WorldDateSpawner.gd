extends Node

var world_date:WorldDate

signal render_map(pos)
signal debug_inf(the_biome:String)

var world_size:float = 4
@export var chunk_range:int = 8  # 区块加载范围，1=1个区块，2=9个区块，3=25个区块...

var loaded_chunks = []  # 已加载完成的区块
var generating_chunks = []  # 正在生成中的区块
var unreacted_chunks = []  # 未反应的区块

@onready var world = get_node("../")
@onready var tilemaplayer0:TileMapLayer = world.get_node("CommonNodeRoot/TileMapLayer0")

var biome_altitude = FastNoiseLite.new()
var biome_temperature = FastNoiseLite.new()
var natural_resources = FastNoiseLite.new()

var chunk_size:int
var tile_size:int

var random:RandomNumberGenerator = RandomNumberGenerator.new()

var map_load_threads = []
var waits = Mutex.new()
var is_quitting = false

# 区块生成状态
var chunk_generation_status = {}  # 记录每个区块的生成状态
var chunk_generation_mutex = Mutex.new()  # 用于同步区块生成状态

func _ready():
	chunk_size = world.chunk_size
	tile_size = preload("res://TilemapLoader/Assets/Tileset.tres").tile_size.x
	world_date = WorldDate.new()
	set_noise()
	
	# 等待一帧确保所有节点都准备好
	await get_tree().process_frame
	on_player_enter_new_chunk(Vector2i.ZERO)

func _exit_tree():
	is_quitting = true
	# 等待所有线程完成
	for thread in map_load_threads:
		if thread.is_started():
			thread.wait_to_finish()

func spawn_map_date(block_name:String, pos:Vector2i) -> void:
	if is_quitting:
		return
		
	if not is_instance_valid(world_date):
		return
		
	var block:Block = load("res://TilemapLoader/Assets/Blocks/" + block_name + ".tres")
	if block == null:
		print_debug(str(block_name)+" is not find")
		return
	world_date.set_block(pos, block)

func set_noise() -> void:
	var world_seed:int = world_date.world_seed
	
	biome_altitude.seed = world_seed
	biome_temperature.seed = world_seed-3
	natural_resources.seed = world_seed-20
	
	biome_altitude.fractal_type = 1
	biome_altitude.domain_warp_enabled = true
	biome_altitude.domain_warp_amplitude = 20
	biome_altitude.domain_warp_fractal_octaves = 20
	biome_altitude.frequency = 0.002 * world_size
	biome_altitude.domain_warp_fractal_lacunarity = 1
	
	biome_temperature.fractal_type = 1
	biome_temperature.domain_warp_enabled = true
	biome_temperature.domain_warp_amplitude = 20
	biome_temperature.domain_warp_fractal_octaves = 20
	biome_temperature.frequency = 0.001 * world_size
	biome_temperature.domain_warp_fractal_lacunarity = 1
	
	natural_resources.noise_type = 0
	natural_resources.fractal_type = 0
	natural_resources.frequency = 0.03
	natural_resources.domain_warp_enabled = true
	natural_resources.frequency = 1

func on_block_reacted(tile_pos:Vector2i):
	var chunk_pos = Vector2i((tile_pos)/chunk_size)
	unreacted_chunks.erase(chunk_pos)

func between(val, start, end):
	if start <= val and val <= end:
		return true
	return false

var tilelin : Vector2i
var last_tile : Vector2i
func _on_player_move(player_pos):
	var tile_pos = Vector2i(player_pos/tile_size)
	tilelin = tile_pos
	if last_tile!= tilelin:
		on_player_enter_new_map_tile(tile_pos)
		last_tile = tilelin

var chunklin : Vector2i
var last_chunk : Vector2i
func on_player_enter_new_map_tile(new_tlie_pos):
	var new_chunk_pos = Vector2i(floor(new_tlie_pos.x / chunk_size), floor(new_tlie_pos.y / chunk_size))
	
	chunklin = new_chunk_pos
	
	if last_chunk!= chunklin:
		on_player_enter_new_chunk(new_chunk_pos)
		last_chunk = chunklin
	emit_signal("debug_inf",world_date.get_position_biome(new_tlie_pos))

func on_player_enter_new_chunk(new_chunk_pos):
	generate_near_chunk(new_chunk_pos)
	# 等待所有区块生成完成后再触发渲染
	await wait_for_chunks_generation()
	emit_signal("render_map",new_chunk_pos)

# 等待区块生成完成
func wait_for_chunks_generation():
	while true:
		chunk_generation_mutex.lock()
		var all_generated = true
		for chunk_pos in generating_chunks:
			if !chunk_generation_status.has(chunk_pos) or !chunk_generation_status[chunk_pos]:
				all_generated = false
				break
		chunk_generation_mutex.unlock()
		
		if all_generated:
			break
		await get_tree().process_frame

func generate_near_chunk(chunk_pos):
	# 根据chunk_range生成需要加载的区块位置
	for x in range(-chunk_range + 1, chunk_range):
		for y in range(-chunk_range + 1, chunk_range):
			var target_chunk = Vector2i(x, y) + chunk_pos
			if !world_date.has_chunk_date(target_chunk) and !generating_chunks.has(target_chunk):
				generating_chunks.append(target_chunk)
				chunk_generation_mutex.lock()
				chunk_generation_status[target_chunk] = false
				chunk_generation_mutex.unlock()
				create_chunk_spawn_thread(target_chunk)

func create_chunk_spawn_thread(chunk_pos):
	if is_quitting:
		return
		
	var map_load = Thread.new()
	map_load_threads.push_back(map_load)
	map_load.start(chunk_spawn_thread.bind(chunk_pos))

func chunk_spawn_thread(chunk_pos):
	if is_quitting:
		return
		
	waits.lock()
	if not is_quitting:
		generate_chunk(chunk_pos)
		# 标记区块生成完成
		chunk_generation_mutex.lock()
		chunk_generation_status[chunk_pos] = true
		chunk_generation_mutex.unlock()
	waits.unlock()

func generate_chunk(chunk_pos):
	if is_quitting:
		return
		
	if not is_instance_valid(world_date):
		return
		
	generate_biome_date(chunk_pos*chunk_size*tile_size)
	generating_chunks.erase(chunk_pos)
	loaded_chunks.append(chunk_pos)
	world_date.add_generated_chunk(chunk_pos)

func get_noise_values(tile_pos: Vector2i, x: int, y: int) -> Dictionary:
	var base_x = tile_pos.x - float(chunk_size)/2 + x
	var base_y = tile_pos.y - float(chunk_size)/2 + y
	return {
		"temp": biome_temperature.get_noise_2d(base_x, base_y) * 10,
		"alt": biome_altitude.get_noise_2d(base_x, base_y) * 10,
		"natural": natural_resources.get_noise_2d(base_x, base_y) * 10
	}

func generate_biome_date(pos):
	if is_quitting:
		return
		
	if not is_instance_valid(tilemaplayer0):
		return
		
	var tile_pos = tilemaplayer0.local_to_map(pos)
	for x in range(chunk_size):
		for y in range(chunk_size):
			if is_quitting:
				return
				
			var vac = Vector2i(tile_pos.x-float(chunk_size)/2 + x, tile_pos.y-float(chunk_size)/2 + y)
			var noise = get_noise_values(tile_pos, x, y)
			
			if noise.alt <= 0:
				world_date.biome_data[vac] = "Sea"
				spawn_map_date("block_water",vac)
			else:
				if noise.temp <= -2:  # 寒带草原
					world_date.biome_data[vac] = "Cold grassland"
					spawn_map_date("block_coldzone_grassland",vac)
					
					if between(noise.natural,0,2):
						spawn_map_date("block_cold_weed",vac)
					
					if between(noise.natural,3,3.2):
						spawn_map_date("block_cold_tree",vac)
					
				elif noise.temp <= 2:  # 温带草原
					world_date.biome_data[vac] = "Grassland"
					spawn_map_date("block_grassland",vac)
					
					if between(noise.natural,0,2):
						spawn_map_date("block_weed",vac)
					
					if between(noise.natural,3,3.2):
						spawn_map_date("block_tree",vac)
						
				else:  # 热带草原
					world_date.biome_data[vac] = "Dry Grassland"
					spawn_map_date("block_dry_grassland",vac)
					
					if between(noise.natural,0,2):
						spawn_map_date("block_dry_weed",vac)
					
					if between(noise.natural,3,3.2):
						spawn_map_date("block_dry_tree",vac)

func clear_chunk():
	generating_chunks.clear()
	loaded_chunks.clear()
	chunk_generation_status.clear()
	
	
	
