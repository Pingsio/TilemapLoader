extends Node2D

var world_date:WorldDate

# 区块和渲染相关常量
@export var chunk_size:int = 16  # 区块大小
@export var initial_chunk_range:int = 4  # 初始区块加载范围，1=1个区块，2=9个区块，3=25个区块...
@export var chunk_update_range:int = 4  # 区块更新范围，1=1个区块，2=9个区块，3=25个区块...
@export var max_chunk_distance:int = 4  # 最大区块距离，超过此距离的区块将被删除

var map_layer_number:int = 3  #TileMapLayer的数量

const MAX_CHUNKS_PER_FRAME = 16  # 每帧最多处理的区块数量，降低每帧处理量但增加处理频率
const MAX_TERRAIN_UPDATES_PER_FRAME = 256  # 每帧最多处理的地形更新数量
const MAX_TERRAIN_UPDATE_ITERATIONS = 5  # 地形更新最大迭代次数

# 区块管理相关变量
var rendered_chunk = []  # 已渲染完成的区块列表
var rendering_chunk = []  # 正在渲染中的区块列表

@onready var layer0: TileMapLayer = $CommonNodeRoot/TileMapLayer0  #地形基础
@onready var layer1: TileMapLayer = $CommonNodeRoot/TileMapLayer1  #地表装饰
@onready var layer2: TileMapLayer = $YSortNodeRoot/TileMapLayer2   #建筑结构

@onready var wait_interface = $WaitCanvasLayer

@onready var world_date_spawner: Node = $WorldDateSpawner   #数据生成器

# 线程同步和区块加载相关变量
var mutex: Mutex  # 线程同步互斥锁
var chunks_to_load: Array = []  # 待加载的区块队列
var chunk_data_queue: Array = []  # 存储准备好的区块数据
var is_thread_active: bool = false  # 线程是否活跃
var delete_chunk_list:Array = []  # 待删除的区块列表
var need_render_chunk = []  # 需要渲染的区块列表
var is_over_render_chunk:bool = false  # 是否完成渲染
var is_exiting: bool = false  # 是否正在退出
var is_processing_chunk: bool = false  # 是否正在处理区块

# 地形更新相关变量
var terrain_update_queue = []  # 地形更新队列
var is_updating_terrain = false  # 是否正在更新地形
var terrain_changesets = {}  # 存储每个层的地形更新changeset
var last_update_time = 0.0  # 上次更新时间
var terrain_update_iterations = 0  # 当前地形更新迭代次数
var processed_positions = {}  # 记录已处理的位置

func _ready():
	# 初始化互斥锁和区块大小
	mutex = Mutex.new()
	world_date = world_date_spawner.world_date
	
	world_date_spawner.render_map.connect(try_render_near_chunk)
	
	on_join_world(Vector2i.ZERO)
	try_render_near_chunk(Vector2i.ZERO)


func _exit_tree():
	# 设置退出标志
	is_exiting = true

# 获取指定索引的图层
func get_layer(layer_index: int) -> TileMapLayer:
	match layer_index:
		0: return layer0  # 底层，可在地图数据中设置0层方块使用
		1: return layer1  # 层
		2: return layer2  # 建筑层
		_: return layer0  # 默认返回基础层

# 根据方块对象设置方块纹理
func set_block_texture_based_block(pos:Vector2i, block:Block) -> void:
	if block.is_single_block:  # 处理单个方块
		get_layer(block.layer).set_cell(pos, block.single_texture_source, block.single_texture_pos)

# 计算两个区块之间的距离
func get_chunk_distance(chunk1: Vector2i, chunk2: Vector2i) -> int:
	var dx = abs(chunk1.x - chunk2.x)
	var dy = abs(chunk1.y - chunk2.y)
	return max(dx, dy)

# 删除过远的区块显示
func remove_distant_chunks(current_chunk: Vector2i):
	var chunks_to_remove = []
	
	# 检查所有已渲染的区块
	for chunk in rendered_chunk:
		if get_chunk_distance(chunk, current_chunk) > max_chunk_distance:
			chunks_to_remove.append(chunk)
	
	# 清除过远区块的显示
	for chunk in chunks_to_remove:
		rendered_chunk.erase(chunk)
		# 清除该区块内的所有图块显示
		var xs = chunk.x * chunk_size + chunk_size/2
		var ys = chunk.y * chunk_size + chunk_size/2
		
		# 遍历区块内的所有位置
		for x in range(xs-chunk_size,xs):
			for y in range(ys-chunk_size,ys):
				var pos = Vector2i(x, y)
				# 只清除 TileMap 显示，不影响地图数据
				for layer in range(map_layer_number):
					get_layer(layer).erase_cell(pos)

# 尝试渲染附近的区块
func try_render_near_chunk(chunk_pos):
	# 删除过远的区块显示
	remove_distant_chunks(chunk_pos)
	
	need_render_chunk = []
	
	# 根据更新范围动态生成需要渲染的区块位置
	var nearby_chunks = []
	for x in range(-chunk_update_range + 1, chunk_update_range):
		for y in range(-chunk_update_range + 1, chunk_update_range):
			nearby_chunks.append(Vector2i(x, y))
	
	# 检查每个周围区块是否需要渲染
	for i in nearby_chunks:
		var target_chunk = i + chunk_pos
		if !rendered_chunk.has(target_chunk) and !rendering_chunk.has(target_chunk):
			if world_date.has_chunk_date(target_chunk):
				load_chunk_tilemap(target_chunk)
			else:
				need_render_chunk.append(target_chunk)

# 加载区块瓦片地图
func load_chunk_tilemap(chunk_pos:Vector2i):
	if is_exiting or !world_date_spawner.loaded_chunks.has(chunk_pos):
		return
		
	need_render_chunk.erase(chunk_pos)
	rendering_chunk.append(chunk_pos)
	
	# 添加到待加载队列
	mutex.lock()
	if !chunks_to_load.has(chunk_pos):
		chunks_to_load.append(chunk_pos)
	mutex.unlock()
	
	if !is_processing_chunk:
		_process_chunks.call_deferred()

# 处理区块加载
func _process_chunks():
	if is_exiting or is_processing_chunk:
		return
		
	is_processing_chunk = true
	
	var local_chunks_to_load = []
	
	# 获取待处理的区块
	mutex.lock()
	local_chunks_to_load = chunks_to_load.slice(0, min(MAX_CHUNKS_PER_FRAME, chunks_to_load.size()))
	chunks_to_load = chunks_to_load.slice(min(MAX_CHUNKS_PER_FRAME, chunks_to_load.size()))
	mutex.unlock()
	
	# 准备区块数据
	var batch_data = []
	for chunk_pos in local_chunks_to_load:
		if is_exiting:
			break
		var chunk_data = prepare_chunk_data(chunk_pos)
		if chunk_data:
			batch_data.append(chunk_data)
	
	# 添加到数据队列
	if !batch_data.is_empty():
		mutex.lock()
		chunk_data_queue.append_array(batch_data)
		mutex.unlock()
	
	is_processing_chunk = false
	
	# 检查是否还有更多区块需要处理
	mutex.lock()
	var has_more = !chunks_to_load.is_empty()
	mutex.unlock()
	
	if has_more:
		_process_chunks.call_deferred()

# 主处理循环
func _process(delta):
	if is_exiting:
		return
		
	var local_chunk_data = []
	
	# 获取待处理的区块数据
	mutex.lock()
	if !chunk_data_queue.is_empty():
		local_chunk_data = chunk_data_queue.slice(0, min(MAX_CHUNKS_PER_FRAME, chunk_data_queue.size()))
		chunk_data_queue = chunk_data_queue.slice(min(MAX_CHUNKS_PER_FRAME, chunk_data_queue.size()))
	mutex.unlock()
	
	# 应用区块数据
	for chunk_data in local_chunk_data:
		if is_exiting:
			break
		if chunk_data:
			_apply_chunk_data(chunk_data)
	
	# 检查是否需要加载新区块
	var should_load = !need_render_chunk.is_empty() and !is_processing_chunk
	
	if should_load:
		if is_over_render_chunk:
			is_over_render_chunk = false
		load_chunk_tilemap(need_render_chunk[0])
	elif !is_over_render_chunk and chunks_to_load.is_empty() and chunk_data_queue.is_empty():
		is_over_render_chunk = true
	
	# 处理地形更新
	_process_terrain_updates(delta)

# 准备区块数据
func prepare_chunk_data(chunk_pos: Vector2i) -> Dictionary:
	var data = {
		"chunk_pos": chunk_pos,
		"terrain_cells": {
			"layer0": [], "layer1": [], "layer2": [], "layer3": []
		}
	}
	
	var xs = chunk_pos.x*chunk_size+chunk_size/2
	var ys = chunk_pos.y*chunk_size+chunk_size/2
	
	var layer_blocks:Dictionary[int,Dictionary] = {0: {}, 1: {}, 2: {}}
	
	# 获取区块内的所有方块数据
	mutex.lock()
	
	# 定义需要检查的范围（包括当前区块和相邻区块的边界）
	var check_range = {
		"x_start": xs - chunk_size - 1,  # 向左扩展1格
		"x_end": xs + 1,                 # 向右扩展1格
		"y_start": ys - chunk_size - 1,  # 向上扩展1格
		"y_end": ys + 1                  # 向下扩展1格
	}
	
	# 获取扩展范围内的所有方块数据（用于地形计算）
	for x in range(check_range.x_start, check_range.x_end):
		for y in range(check_range.y_start, check_range.y_end):
			var pos = Vector2i(x, y)
			for layer in range(map_layer_number):
				if world_date.has_block(pos, layer):
					layer_blocks[layer][pos] = world_date.get_block_attribute_render(pos, layer)
	
	mutex.unlock()
	
	# 处理所有方块，但只放置当前区块内的图块
	for layer:int in layer_blocks:
		for pos:Vector2i in layer_blocks[layer]:
			var block:Block = layer_blocks[layer][pos]
			if block == null:
				continue
			
			# 只处理当前区块内的方块
			if (pos.x >= xs-chunk_size and pos.x < xs and
				pos.y >= ys-chunk_size and pos.y < ys):
				if block.is_single_block:
					set_block_texture_based_block(pos, block)
				else:
					data.terrain_cells["layer" + str(layer)].append({
						"pos": pos,
						"source": block.terrain_source
					})
	
	return data

# 应用区块数据
func _apply_chunk_data(data: Dictionary):
	# 处理地形单元格，确保所有位置都被处理
	for layer in range(map_layer_number):
		var terrain_cells = data.terrain_cells["layer" + str(layer)]
		if !terrain_cells.is_empty():
			# 将地形数据添加到更新队列，确保所有位置都被添加
			terrain_update_queue.append({
				"layer": layer,
				"positions": terrain_cells.map(func(cell): return cell.pos)
			})
	
	# 更新区块状态
	rendering_chunk.erase(data.chunk_pos)
	rendered_chunk.append(data.chunk_pos)
	
	# 检查相邻的已渲染区块，更新边界处的方块地形
	var chunk_pos = data.chunk_pos
	var xs = chunk_pos.x*chunk_size+chunk_size/2
	var ys = chunk_pos.y*chunk_size+chunk_size/2
	
	# 检查四个方向的相邻区块
	var neighbor_offsets = [
		Vector2i(-1, 0),  # 左
		Vector2i(1, 0),   # 右
		Vector2i(0, -1),  # 上
		Vector2i(0, 1)    # 下
	]
	
	for offset in neighbor_offsets:
		var neighbor_chunk = chunk_pos + offset
		if rendered_chunk.has(neighbor_chunk):
			var nx = neighbor_chunk.x*chunk_size+chunk_size/2
			var ny = neighbor_chunk.y*chunk_size+chunk_size/2
			
			# 确定需要更新的边界范围
			var update_positions = []
			
			if offset.x == -1:  # 左侧区块
				# 更新当前区块的左边界和相邻区块的右边界
				for y in range(ys-chunk_size, ys):
					update_positions.append(Vector2i(xs-chunk_size, y))  # 当前区块左边界
					update_positions.append(Vector2i(nx-1, y))  # 相邻区块右边界
			elif offset.x == 1:  # 右侧区块
				# 更新当前区块的右边界和相邻区块的左边界
				for y in range(ys-chunk_size, ys):
					update_positions.append(Vector2i(xs-1, y))  # 当前区块右边界
					update_positions.append(Vector2i(nx-chunk_size, y))  # 相邻区块左边界
			elif offset.y == -1:  # 上方区块
				# 更新当前区块的上边界和相邻区块的下边界
				for x in range(xs-chunk_size, xs):
					update_positions.append(Vector2i(x, ys-chunk_size))  # 当前区块上边界
					update_positions.append(Vector2i(x, ny-1))  # 相邻区块下边界
			elif offset.y == 1:  # 下方区块
				# 更新当前区块的下边界和相邻区块的上边界
				for x in range(xs-chunk_size, xs):
					update_positions.append(Vector2i(x, ys-1))  # 当前区块下边界
					update_positions.append(Vector2i(x, ny-chunk_size))  # 相邻区块上边界
			
			# 将边界位置添加到更新队列
			for layer in range(map_layer_number):
				terrain_update_queue.append({
					"layer": layer,
					"positions": update_positions
				})

# 处理地形更新队列
func _process_terrain_update_queue():
	if terrain_update_queue.is_empty():
		is_updating_terrain = false
		terrain_update_iterations = 0
		processed_positions.clear()
		return
	
	
	is_updating_terrain = true
	
	var layer_positions = {}
	var updates_processed = 0
	
	# 处理更新队列，确保所有位置都被处理
	while !terrain_update_queue.is_empty() and updates_processed < MAX_TERRAIN_UPDATES_PER_FRAME:
		var update_task = terrain_update_queue.pop_front()
		var layer = update_task.layer
		var positions = update_task.positions
		
		if !layer_positions.has(layer):
			layer_positions[layer] = []
		
		# 确保所有位置都被添加到处理列表
		for pos in positions:
			var pos_key = str(layer) + "_" + str(pos)
			if !processed_positions.has(pos_key):
				layer_positions[layer].append(pos)
				processed_positions[pos_key] = true
				updates_processed += 1
		
		# 如果还有未处理的位置，将任务重新加入队列
		if positions.size() > updates_processed:
			terrain_update_queue.push_back({
				"layer": layer,
				"positions": positions.slice(updates_processed)
			})
	
	# 创建地形更新changeset，确保所有位置都被更新
	for layer in layer_positions:
		var positions = layer_positions[layer]
		if positions.is_empty():
			continue
		
		var paint = {}
		for pos in positions:
			# 从world_date获取方块数据
			if world_date.has_block(pos, layer):
				var block = world_date.get_block_attribute_render(pos, layer)
				if block != null and !block.is_single_block:
					paint[pos] = block.terrain_source
		
		if !paint.is_empty():
			terrain_changesets[layer] = BetterTerrain.create_terrain_changeset(get_layer(layer), paint)
	
	terrain_update_iterations += 1
	
	# 检查是否达到最大迭代次数
	if terrain_update_iterations >= MAX_TERRAIN_UPDATE_ITERATIONS:
		# 将未处理完的任务重新加入队列
		for layer in layer_positions:
			var positions = layer_positions[layer]
			if positions.size() > updates_processed:
				terrain_update_queue.push_back({
					"layer": layer,
					"positions": positions.slice(updates_processed)
				})
		terrain_update_iterations = 0
		processed_positions.clear()

# 处理地形更新
func _process_terrain_updates(delta):
	var all_changesets_completed = true
	
	# 应用已完成的changeset
	for layer in terrain_changesets.keys():
		var changeset = terrain_changesets[layer]
		if BetterTerrain.is_terrain_changeset_ready(changeset):
			BetterTerrain.apply_terrain_changeset(changeset)
			terrain_changesets.erase(layer)
		else:
			all_changesets_completed = false
	
	# 重置状态
	if all_changesets_completed:
		is_updating_terrain = false
		terrain_update_iterations = 0
		processed_positions.clear()
	
	# 处理新的地形更新
	if !is_updating_terrain and !terrain_update_queue.is_empty():
		_process_terrain_update_queue()

# 玩家加入世界时的处理
func on_join_world(player_chunk_pos:Vector2i):
	# 显示加载界面
	wait_interface.show()
	
	# 根据initial_chunk_range生成需要加载的区块位置
	var chunks_to_generate = []
	
	# 生成区块位置列表
	for x in range(-initial_chunk_range + 1, initial_chunk_range):
		for y in range(-initial_chunk_range + 1, initial_chunk_range):
			chunks_to_generate.append(Vector2i(x, y))
	
	# 生成和加载区块
	for i in chunks_to_generate:
		var target_chunk = i + player_chunk_pos
		if world_date.generated_chunks.has(target_chunk):
			load_chunk_sync(target_chunk)
		else:
			world_date_spawner.generate_chunk(target_chunk)
			load_chunk_sync(target_chunk)
		rendered_chunk.append(target_chunk)
	
	# 等待所有地形更新完成
	await get_tree().create_timer(0.1).timeout  # 给一个短暂的延迟确保所有更新都被加入队列
	while !terrain_update_queue.is_empty() or is_updating_terrain:
		await get_tree().create_timer(0.1).timeout
	
	# 隐藏加载界面
	wait_interface.hide()

# 同步加载区块（用于初始加载）
func load_chunk_sync(chunk_pos:Vector2i):
	if is_exiting or !world_date_spawner.loaded_chunks.has(chunk_pos):
		return
		
	rendering_chunk.append(chunk_pos)
	
	var xs = chunk_pos.x*chunk_size+chunk_size/2
	var ys = chunk_pos.y*chunk_size+chunk_size/2
	
	# 处理区块内的所有方块
	for x in range(xs-chunk_size,xs):
		for y in range(ys-chunk_size,ys):
			var pos = Vector2i(x,y)
			for layer in range(map_layer_number):
				if world_date.has_block(pos, layer):
					var block = world_date.get_block_attribute_render(pos, layer)
					if block == null:
						continue
					
					if block.is_single_block:
						set_block_texture_based_block(pos, block)
					else:
						BetterTerrain.set_cell(get_layer(layer), pos, block.terrain_source)
	
	# 将区块添加到地形更新队列
	for layer in range(map_layer_number):
		var positions = []
		# 收集区块内的所有位置
		for x in range(xs-chunk_size,xs):
			for y in range(ys-chunk_size,ys):
				positions.append(Vector2i(x,y))
		
		# 添加到更新队列
		if !positions.is_empty():
			terrain_update_queue.append({
				"layer": layer,
				"positions": positions
			})
	
	# 检查相邻的已渲染区块，更新边界处的方块地形
	var neighbor_offsets = [
		Vector2i(-1, 0),  # 左
		Vector2i(1, 0),   # 右
		Vector2i(0, -1),  # 上
		Vector2i(0, 1)    # 下
	]
	
	for offset in neighbor_offsets:
		var neighbor_chunk = chunk_pos + offset
		if rendered_chunk.has(neighbor_chunk):
			var nx = neighbor_chunk.x*chunk_size+chunk_size/2
			var ny = neighbor_chunk.y*chunk_size+chunk_size/2
			
			# 确定需要更新的边界范围
			var update_positions = []
			
			if offset.x == -1:  # 左侧区块
				# 更新当前区块的左边界和相邻区块的右边界
				for y in range(ys-chunk_size, ys):
					update_positions.append(Vector2i(xs-chunk_size, y))  # 当前区块左边界
					update_positions.append(Vector2i(nx-1, y))  # 相邻区块右边界
			elif offset.x == 1:  # 右侧区块
				# 更新当前区块的右边界和相邻区块的左边界
				for y in range(ys-chunk_size, ys):
					update_positions.append(Vector2i(xs-1, y))  # 当前区块右边界
					update_positions.append(Vector2i(nx-chunk_size, y))  # 相邻区块左边界
			elif offset.y == -1:  # 上方区块
				# 更新当前区块的上边界和相邻区块的下边界
				for x in range(xs-chunk_size, xs):
					update_positions.append(Vector2i(x, ys-chunk_size))  # 当前区块上边界
					update_positions.append(Vector2i(x, ny-1))  # 相邻区块下边界
			elif offset.y == 1:  # 下方区块
				# 更新当前区块的下边界和相邻区块的上边界
				for x in range(xs-chunk_size, xs):
					update_positions.append(Vector2i(x, ys-1))  # 当前区块下边界
					update_positions.append(Vector2i(x, ny-chunk_size))  # 相邻区块上边界
			
			# 将边界位置添加到更新队列
			for layer in range(map_layer_number):
				terrain_update_queue.append({
					"layer": layer,
					"positions": update_positions
				})
	
	rendering_chunk.erase(chunk_pos)
