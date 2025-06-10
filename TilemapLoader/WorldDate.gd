extends Resource

class_name WorldDate

# 使用分层存储结构
@export var block_layers: Array[Dictionary] = [
	{}, # Layer 0
	{}, # Layer 1 
	{}, # Layer 2
]

@export var biome_data: Dictionary[Vector2i, String] = {}
@export var generated_chunks: Array[Vector2i] = []
@export var world_seed: int



# 辅助函数
func get_block_data(pos: Vector2i, layer: int) -> BlockData:
	if layer < 0 or layer >= block_layers.size():
		return null
	return block_layers[layer].get(pos)

func set_block_data(pos: Vector2i, layer: int, data: BlockData) -> void:
	if layer < 0 or layer >= block_layers.size():
		return
	block_layers[layer][pos] = data

func has_block(pos: Vector2i, layer: int = -1) -> bool:
	if layer != -1:
		return block_layers[layer].has(pos)
	
	for layer_dict in block_layers:
		if layer_dict.has(pos):
			return true
	return false

func get_world_seed() -> int:
	return world_seed

func clean_world_date():
	generated_chunks = []
	biome_data = {}
	for i in range(block_layers.size()):
		block_layers[i] = {}


func add_generated_chunk(pos: Vector2i):
	if generated_chunks.has(pos): return
	generated_chunks.append(pos)

func has_chunk_date(pos: Vector2i) -> bool:
	return generated_chunks.has(pos)

func set_block(pos: Vector2i, block: Block) -> bool:
	var data = BlockData.new(block)
	
	set_block_data(pos, block.layer, data)
	
	return true

func get_block_attribute(pos: Vector2i, layer: int = -1) -> Block:
	if !has_block(pos):
		return null
		
	if layer != -1:
		var data = get_block_data(pos, layer)
		if data:
			return data.block
		return null
			
	for traversal_layer in [2,1,0]:
		var data = get_block_data(pos, traversal_layer)
		if data:
			return data.block
	return null

func get_block_date(pos: Vector2i, layer: int = -1) -> Dictionary:
	if !has_block(pos):
		return {}
		
	if layer != -1:
		var data = get_block_data(pos, layer)
		if data:
			return data.additional_data
		return {}
			
	for traversal_layer in [2,1,0]:
		var data = get_block_data(pos, traversal_layer)
		if data:
			return data.additional_data
	return {}

func get_block_hardness(pos: Vector2i, layer: int = -1) -> int:
	if !has_block(pos):
		return 0
		
	if layer != -1:
		var data = get_block_data(pos, layer)
		if data:
			return data.hardness
		return 0
			
	for traversal_layer in [2,1,0]:
		var data = get_block_data(pos, traversal_layer)
		if data:
			return data.hardness
	return 0

func set_block_hardness(pos: Vector2i, layer: int = -1, num: int = 1) -> bool:
	if !has_block(pos):
		return false
		
	if layer != -1:
		var data = get_block_data(pos, layer)
		if data:
			data.hardness = num
			if data.hardness <= 0:
				delete_block(pos, layer)
				return true
			return false
		return false
			
	for traversal_layer in [2,1,0]:
		var data = get_block_data(pos, traversal_layer)
		if data:
			data.hardness = num
			if data.hardness <= 0:
				delete_block(pos, traversal_layer)
				return true
			return false
	return false

func block_hardness_minus(pos: Vector2i, layer: int = -1, num: int = 1) -> bool:
	if !has_block(pos):
		return false
		
	if layer != -1:
		var data = get_block_data(pos, layer)
		if data:
			data.hardness -= num
			if data.hardness <= 0:
				delete_block(pos, layer)
				return true
			return false
		return false
			
	for traversal_layer in [2,1,0]:
		var data = get_block_data(pos, traversal_layer)
		if data:
			data.hardness -= num
			if data.hardness <= 0:
				delete_block(pos, traversal_layer)
				return true
			return false
	return false

func delete_block(pos: Vector2i, layer: int = -1) -> void:
	if !has_block(pos, layer):
		return
		
	if layer != -1:
		var data = get_block_data(pos, layer)
		if data and data.block:
			block_layers[layer].erase(pos)
		return
	
	for traversal_layer in [2,1,0]:
		var data = get_block_data(pos, traversal_layer)
		if data and data.block:
			block_layers[traversal_layer].erase(pos)
			return


func get_position_biome(pos: Vector2i) -> String:
	return biome_data.get(pos, "null")





func get_block_attribute_render(pos: Vector2i, layer: int = -1) -> Block:
	if !has_block(pos):
		return null
	if layer != -1:
		var data = get_block_data(pos, layer)
		if data:
			return data.block
		return null
			
	for traversal_layer in [2,1,0]:
		var data = get_block_data(pos, traversal_layer)
		if data:
			return data.block
	return null

func get_block_state(pos: Vector2i, layer: int = -1, state = null):
	if state == null:return null
	if get_block_attribute(pos, layer) != null:
		return get_block_attribute(pos, layer).get_block_state(state)
	

	
func get_block_stack(pos: Vector2i, layer: int = -1) -> Dictionary:
	if !has_block(pos):
		return {}
	if layer != -1:
		var data = get_block_data(pos, layer)
		if data:
			var date_dict = {
				"hardness": data.hardness,
				"texture_pos": data.texture_pos,
				"main_block_pos": data.main_block_pos
			}
			for key in data.additional_data:
				date_dict[key] = data.additional_data[key]
			return {
				"type": data.block,
				"date": date_dict
			}
		return {}
			
	for traversal_layer in [2,1,0]:
		var data = get_block_data(pos, traversal_layer)
		if data:
			var date_dict = {
				"hardness": data.hardness,
				"texture_pos": data.texture_pos,
				"main_block_pos": data.main_block_pos
			}
			for key in data.additional_data:
				date_dict[key] = data.additional_data[key]
			return {
				"type": data.block,
				"date": date_dict
			}
	return {}
	
func set_block_date(pos: Vector2i, layer: int = -1, set_date_name: String = "", set_value = 0):
	if !has_block(pos):
		return
	if layer != -1:
		var data = get_block_data(pos, layer)
		if data:
			data.additional_data[set_date_name] = set_value
		return
			
	for traversal_layer in [2,1,0]:
		var data = get_block_data(pos, traversal_layer)
		if data:
			data.additional_data[set_date_name] = set_value
			return


#func get_block_type(pos: Vector2i, layer: int) -> String:
	#var data = get_block_data(pos, layer)
	#if data and data.block:
		#return data.block.resource_name
	#return ""
