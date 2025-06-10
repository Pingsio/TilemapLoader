@tool
extends Node

## 一个 [TileMapLayer] 地形/自动平铺系统。
##
## 这是 Godot 4 的 tilemap 地形系统的替代品，提供更通用和直接的自动平铺功能。
## 它可以通过编辑器插件或直接通过代码与任何现有的 [TileMapLayer] 或 [TileSet] 一起使用。
## [br][br]
## [b]BetterTerrain[/b] 类只包含静态函数，每个函数都接受 [TileMapLayer]、[TileSet]，
## 有时还接受 [TileData]。元数据被嵌入到 [TileSet] 和 [TileData] 类型中以存储地形信息。
## 有关信息，请参见 [method Object.get_meta]。
## [br][br]
## 一旦地形设置完成，就可以使用 [method set_cells] 将其写入 tilemap。
## 与 Godot 3.x 类似，设置单元格不会运行地形求解器，所以在设置单元格后，
## 你需要调用更新函数，如 [method update_terrain_cells]。


## 用于存储地形信息的元数据键。
const TERRAIN_META = &"_better_terrain"

## 当前版本。用于处理未来的升级。
const TERRAIN_SYSTEM_VERSION = "0.2"

var _tile_cache = {}
var rng = RandomNumberGenerator.new()
var use_seed := true

## A helper class that provides functions detailing valid peering bits and
## polygons for different tile types.
var data := load("res://addons/better-terrain/BetterTerrainData.gd"):
	get:
		return data

enum TerrainType {
	MATCH_TILES, ## Selects tiles by matching against adjacent tiles.
	MATCH_VERTICES, ## Select tiles by analysing vertices, similar to wang-style tiles.
	CATEGORY, ## Declares a matching type for more sophisticated rules.
	DECORATION, ## Fills empty tiles by matching adjacent tiles
	MAX,
}

enum TileCategory {
	EMPTY = -1, ## An empty cell, or a tile marked as decoration
	NON_TERRAIN = -2, ## A non-empty cell that does not contain a terrain tile
	ERROR = -3
}

enum SymmetryType {
	NONE,
	MIRROR, ## Horizontally mirror
	FLIP, ## Vertically flip
	REFLECT, ## All four reflections
	ROTATE_CLOCKWISE,
	ROTATE_COUNTER_CLOCKWISE,
	ROTATE_180,
	ROTATE_ALL, ## All four rotated forms
	ALL ## All rotated and reflected forms
}


func _intersect(first: Array, second: Array) -> bool:
	if first.size() > second.size():
		return _intersect(second, first) # Array 'has' is fast compared to gdscript loop
	for f in first:
		if second.has(f):
			return true
	return false


# Meta-data functions

func _get_terrain_meta(ts: TileSet) -> Dictionary:
	return ts.get_meta(TERRAIN_META) if ts and ts.has_meta(TERRAIN_META) else {
		terrains = [],
		decoration = ["Decoration", Color.DIM_GRAY, TerrainType.DECORATION, [], {path = "res://addons/better-terrain/icons/Decoration.svg"}],
		version = TERRAIN_SYSTEM_VERSION
	}


func _set_terrain_meta(ts: TileSet, meta : Dictionary) -> void:
	ts.set_meta(TERRAIN_META, meta)
	ts.emit_changed()


func _get_tile_meta(td: TileData) -> Dictionary:
	return td.get_meta(TERRAIN_META) if td.has_meta(TERRAIN_META) else {
		type = TileCategory.NON_TERRAIN
	}


func _set_tile_meta(ts: TileSet, td: TileData, meta) -> void:
	td.set_meta(TERRAIN_META, meta)
	ts.emit_changed()


func _get_cache(ts: TileSet) -> Array:
	if _tile_cache.has(ts):
		return _tile_cache[ts]
	
	var cache := []
	if !ts:
		return cache
	_tile_cache[ts] = cache

	var watcher = Node.new()
	watcher.set_script(load("res://addons/better-terrain/Watcher.gd"))
	watcher.tileset = ts
	watcher.trigger.connect(_purge_cache.bind(ts))
	add_child(watcher)
	ts.changed.connect(watcher.activate)
	
	var types = {}
	
	var ts_meta := _get_terrain_meta(ts)
	for t in ts_meta.terrains.size():
		var terrain = ts_meta.terrains[t]
		var bits = terrain[3].duplicate()
		bits.push_back(t)
		types[t] = bits
		cache.push_back([])
	
	# Decoration
	types[-1] = [TileCategory.EMPTY]
	cache.push_back([[-1, Vector2.ZERO, -1, {}, 1.0]])
	
	for s in ts.get_source_count():
		var source_id := ts.get_source_id(s)
		var source := ts.get_source(source_id) as TileSetAtlasSource
		if !source:
			continue
		source.changed.connect(watcher.activate)
		for c in source.get_tiles_count():
			var coord := source.get_tile_id(c)
			for a in source.get_alternative_tiles_count(coord):
				var alternate := source.get_alternative_tile_id(coord, a)
				var td := source.get_tile_data(coord, alternate)
				var td_meta := _get_tile_meta(td)
				if td_meta.type < TileCategory.EMPTY or td_meta.type >= cache.size():
					continue
				
				td.changed.connect(watcher.activate)
				var peering := {}
				for key in td_meta.keys():
					if !(key is int):
						continue
					
					var targets := []
					for k in types:
						if _intersect(types[k], td_meta[key]):
							targets.push_back(k)
					
					peering[key] = targets
				
				# Decoration tiles without peering are skipped
				if td_meta.type == TileCategory.EMPTY and !peering:
					continue
				
				var symmetry = td_meta.get("symmetry", SymmetryType.NONE)
				# Branch out no symmetry tiles early
				if symmetry == SymmetryType.NONE:
					cache[td_meta.type].push_back([source_id, coord, alternate, peering, td.probability])
					continue
				
				# calculate the symmetry order for this tile
				var symmetry_order := 0
				for flags in data.symmetry_mapping[symmetry]:
					var symmetric_peering = data.peering_bits_after_symmetry(peering, flags)
					if symmetric_peering == peering:
						symmetry_order += 1
				
				var adjusted_probability = td.probability / symmetry_order
				for flags in data.symmetry_mapping[symmetry]:
					var symmetric_peering = data.peering_bits_after_symmetry(peering, flags)
					cache[td_meta.type].push_back([source_id, coord, alternate | flags, symmetric_peering, adjusted_probability])
	
	return cache


func _get_cache_terrain(ts_meta : Dictionary, index: int) -> Array:
	# the cache and the terrains in ts_meta don't line up because
	# decorations are cached too
	if index < 0 or index >= ts_meta.terrains.size():
		return ts_meta.decoration
	return ts_meta.terrains[index]


func _purge_cache(ts: TileSet) -> void:
	_tile_cache.erase(ts)
	for c in get_children():
		if c.tileset == ts:
			c.tidy()
			break


func _clear_invalid_peering_types(ts: TileSet) -> void:
	var ts_meta := _get_terrain_meta(ts)
	
	var cache := _get_cache(ts)
	for t in cache.size():
		var type = _get_cache_terrain(ts_meta, t)[2]
		var valid_peering_types = data.get_terrain_peering_cells(ts, type)
		
		for c in cache[t]:
			if c[0] < 0:
				continue
			var source := ts.get_source(c[0]) as TileSetAtlasSource
			if !source:
				continue
			var td := source.get_tile_data(c[1], c[2])
			var td_meta := _get_tile_meta(td)
			
			for peering in c[3].keys():
				if valid_peering_types.has(peering):
					continue
				td_meta.erase(peering)
			
			_set_tile_meta(ts, td, td_meta)
	
	# Not strictly necessary
	_purge_cache(ts)


func _has_invalid_peering_types(ts: TileSet) -> bool:
	var ts_meta := _get_terrain_meta(ts)
	
	var cache := _get_cache(ts)
	for t in cache.size():
		var type = _get_cache_terrain(ts_meta, t)[2]
		var valid_peering_types = data.get_terrain_peering_cells(ts, type)
		
		for c in cache[t]:
			for peering in c[3].keys():
				if !valid_peering_types.has(peering):
					return true
	
	return false


func _update_terrain_data(ts: TileSet) -> void:
	var ts_meta = _get_terrain_meta(ts)
	var previous_version = ts_meta.get("version")
	
	# First release: no version info
	if !ts_meta.has("version"):
		ts_meta["version"] = "0.0"
	
	# 0.0 -> 0.1: add categories
	if ts_meta.version == "0.0":
		for t in ts_meta.terrains:
			if t.size() == 3:
				t.push_back([])
		ts_meta.version = "0.1"
	
	# 0.1 -> 0.2: add decoration tiles and terrain icons
	if ts_meta.version == "0.1":
		# Add terrain icon containers
		for t in ts_meta.terrains:
			if t.size() == 4:
				t.push_back({})
		
		# Add default decoration data
		ts_meta["decoration"] = ["Decoration", Color.DIM_GRAY, TerrainType.DECORATION, [], {path = "res://addons/better-terrain/icons/Decoration.svg"}]
		ts_meta.version = "0.2"
	
	if previous_version != ts_meta.version:
		_set_terrain_meta(ts, ts_meta)


func _weighted_selection(choices: Array, apply_empty_probability: bool):
	if choices.is_empty():
		return null
	
	var weight = choices.reduce(func(a, c): return a + c[4], 0.0)
	
	if apply_empty_probability and weight < 1.0 and rng.randf() > weight:
		return [-1, Vector2.ZERO, -1, null, 1.0]
	
	if choices.size() == 1:
		return choices[0]
	
	if weight == 0.0:
		return choices[rng.randi() % choices.size()]
	
	var pick = rng.randf() * weight
	for c in choices:
		if pick < c[4]:
			return c
		pick -= c[4]
	return choices.back()


func _weighted_selection_seeded(choices: Array, coord: Vector2i, apply_empty_probability: bool):
	if use_seed:
		rng.seed = hash(coord)
	return _weighted_selection(choices, apply_empty_probability)


func _update_tile_tiles(tm: TileMapLayer, coord: Vector2i, types: Dictionary, cache: Array, apply_empty_probability: bool):
	var type = types[coord]
	
	const reward := 3
	var penalty := -2000 if apply_empty_probability else -10
	
	var best_score := -1000 # Impossibly bad score
	var best := []
	for t in cache[type]:
		var score := 0
		for peering in t[3]:
			score += reward if t[3][peering].has(types[tm.get_neighbor_cell(coord, peering)]) else penalty
		
		if score > best_score:
			best_score = score
			best = [t]
		elif score == best_score:
			best.append(t)
	
	return _weighted_selection_seeded(best, coord, apply_empty_probability)


func _probe(tm: TileMapLayer, coord: Vector2i, peering: int, type: int, types: Dictionary) -> int:
	var targets = data.associated_vertex_cells(tm, coord, peering)
	targets = targets.map(func(c): return types[c])
	
	var first = targets[0]
	if targets.all(func(t): return t == first):
		return first
	
	# if different, use the lowest  non-same
	targets = targets.filter(func(t): return t != type)
	return targets.reduce(func(a, t): return min(a, t))


func _update_tile_vertices(tm: TileMapLayer, coord: Vector2i, types: Dictionary, cache: Array):
	var type = types[coord]
	
	const reward := 3
	const penalty := -10
	
	var best_score := -1000 # Impossibly bad score
	var best := []
	for t in cache[type]:
		var score := 0
		for peering in t[3]:
			score += reward if _probe(tm, coord, peering, type, types) in t[3][peering] else penalty
		
		if score > best_score:
			best_score = score
			best = [t]
		elif score == best_score:
			best.append(t)
	
	return _weighted_selection_seeded(best, coord, false)


func _update_tile_immediate(tm: TileMapLayer, coord: Vector2i, ts_meta: Dictionary, types: Dictionary, cache: Array) -> void:
	var type = types[coord]
	if type < TileCategory.EMPTY or type >= ts_meta.terrains.size():
		return
	
	var placement
	var terrain = _get_cache_terrain(ts_meta, type)
	if terrain[2] in [TerrainType.MATCH_TILES, TerrainType.DECORATION]:
		placement = _update_tile_tiles(tm, coord, types, cache, terrain[2] == TerrainType.DECORATION)
	elif terrain[2] == TerrainType.MATCH_VERTICES:
		placement = _update_tile_vertices(tm, coord, types, cache)
	else:
		return
	
	if placement:
		tm.set_cell(coord, placement[0], placement[1], placement[2])


func _update_tile_deferred(tm: TileMapLayer, coord: Vector2i, ts_meta: Dictionary, types: Dictionary, cache: Array):
	var type = types[coord]
	if type >= TileCategory.EMPTY and type < ts_meta.terrains.size():
		var terrain = _get_cache_terrain(ts_meta, type)
		if terrain[2] in [TerrainType.MATCH_TILES, TerrainType.DECORATION]:
			return _update_tile_tiles(tm, coord, types, cache, terrain[2] == TerrainType.DECORATION)
		elif terrain[2] == TerrainType.MATCH_VERTICES:
			return _update_tile_vertices(tm, coord, types, cache)
	return null


func _widen(tm: TileMapLayer, coords: Array) -> Array:
	var result := {}
	var peering_neighbors = data.get_terrain_peering_cells(tm.tile_set, TerrainType.MATCH_TILES)
	for c in coords:
		result[c] = true
		var neighbors = data.neighboring_coords(tm, c, peering_neighbors)
		for t in neighbors:
			result[t] = true
	return result.keys()


func _widen_with_exclusion(tm: TileMapLayer, coords: Array, exclusion: Rect2i) -> Array:
	var result := {}
	var peering_neighbors = data.get_terrain_peering_cells(tm.tile_set, TerrainType.MATCH_TILES)
	for c in coords:
		if !exclusion.has_point(c):
			result[c] = true
		var neighbors = data.neighboring_coords(tm, c, peering_neighbors)
		for t in neighbors:
			if !exclusion.has_point(t):
				result[t] = true
	return result.keys()

# Terrains

## 返回一个类别数组。这些是 [TileSet] 中被标记为 [enum TerrainType] 的 [code]CATEGORY[/code] 的地形。
## 数组中的每个条目都是一个 [Dictionary]，包含 [code]name[/code]、[code]color[/code] 和 [code]id[/code]。
func get_terrain_categories(ts: TileSet) -> Array:
	var result := []
	if !ts:
		return result
	
	var ts_meta := _get_terrain_meta(ts)
	for id in ts_meta.terrains.size():
		var t = ts_meta.terrains[id]
		if t[2] == TerrainType.CATEGORY:
			result.push_back({name = t[0], color = t[1], id = id})
	
	return result


## 向 [TileSet] 添加新地形。如果成功则返回 [code]true[/code]。
## [br][br]
## [code]type[/code] 必须是 [enum TerrainType] 之一。[br]
## [code]categories[/code] 是这个地形可以匹配的地形类别的索引列表。
## 索引必须是 CATEGORY 类型的有效地形。
## [code]icon[/code] 是一个 [Dictionary]，包含指向资源的 [code]path[/code] 字符串，
## 或者 [code]source_id[/code] [int] 和 [code]coord[/code] [Vector2i]。
## 如果两者都存在，前者优先。
func add_terrain(ts: TileSet, name: String, color: Color, type: int, categories: Array = [], icon: Dictionary = {}) -> bool:
	if !ts or name.is_empty() or type < 0 or type == TerrainType.DECORATION or type >= TerrainType.MAX:
		return false
	
	var ts_meta := _get_terrain_meta(ts)
	
	# check categories
	if type == TerrainType.CATEGORY and !categories.is_empty():
		return false
	for c in categories:
		if c < 0 or c >= ts_meta.terrains.size() or ts_meta.terrains[c][2] != TerrainType.CATEGORY:
			return false
	
	if icon and not (icon.has("path") or (icon.has("source_id") and icon.has("coord"))):
		return false
	
	ts_meta.terrains.push_back([name, color, type, categories, icon])
	_set_terrain_meta(ts, ts_meta)
	_purge_cache(ts)
	return true


## 从 [TileSet] 中删除索引为 [code]index[/code] 的地形。如果删除成功则返回 [code]true[/code]。
func remove_terrain(ts: TileSet, index: int) -> bool:
	if !ts or index < 0:
		return false
	
	var ts_meta := _get_terrain_meta(ts)
	if index >= ts_meta.terrains.size():
		return false
	
	if ts_meta.terrains[index][2] == TerrainType.CATEGORY:
		for t in ts_meta.terrains:
			t[3].erase(index)
	
	for s in ts.get_source_count():
		var source := ts.get_source(ts.get_source_id(s)) as TileSetAtlasSource
		if !source:
			continue
		for t in source.get_tiles_count():
			var coord := source.get_tile_id(t)
			for a in source.get_alternative_tiles_count(coord):
				var alternate := source.get_alternative_tile_id(coord, a)
				var td := source.get_tile_data(coord, alternate)
				
				var td_meta := _get_tile_meta(td)
				if td_meta.type == TileCategory.NON_TERRAIN:
					continue
				
				if td_meta.type == index:
					_set_tile_meta(ts, td, null)
					continue
				
				if td_meta.type > index:
					td_meta.type -= 1
				
				for peering in td_meta.keys():
					if !(peering is int):
						continue
					
					var fixed_peering = []
					for p in td_meta[peering]:
						if p < index:
							fixed_peering.append(p)
						elif p > index:
							fixed_peering.append(p - 1)
					
					if fixed_peering.is_empty():
						td_meta.erase(peering)
					else:
						td_meta[peering] = fixed_peering
				
				_set_tile_meta(ts, td, td_meta)
	
	ts_meta.terrains.remove_at(index)
	_set_terrain_meta(ts, ts_meta)
	
	_purge_cache(ts)	
	return true


## 返回 [TileSet] 中的地形数量。
func terrain_count(ts: TileSet) -> int:
	if !ts:
		return 0
	
	var ts_meta := _get_terrain_meta(ts)
	return ts_meta.terrains.size()


## 获取 [TileSet] 中索引为 [code]index[/code] 的地形信息。
## [br][br]
## 返回描述地形的 [Dictionary]。如果成功，键 [code]valid[/code] 将被设置为 [code]true[/code]。
## 其他键包括 [code]name[/code]、[code]color[/code]、[code]type[/code]（一个 [enum TerrainType]）、
## [code]categories[/code]（这个地形可以匹配的地形类别类型的数组）和 [code]icon[/code]
## （一个包含 [code]path[/code] [String] 或 [code]source_id[/code] [int] 和 [code]coord[/code] [Vector2i] 的 [Dictionary]）
func get_terrain(ts: TileSet, index: int) -> Dictionary:
	if !ts or index < TileCategory.EMPTY:
		return {valid = false}
	
	var ts_meta := _get_terrain_meta(ts)
	if index >= ts_meta.terrains.size():
		return {valid = false}
	
	var terrain := _get_cache_terrain(ts_meta, index)
	return {
		id = index,
		name = terrain[0],
		color = terrain[1],
		type = terrain[2],
		categories = terrain[3].duplicate(),
		icon = terrain[4].duplicate(),
		valid = true
	}


## 更新 [TileSet] 中索引为 [code]index[/code] 的地形的详细信息。如果成功则返回 [code]true[/code]。
## [br][br]
## 如果提供，[code]categories[/code] 必须是其他 [code]CATEGORY[/code] 类型地形的索引列表。
## [code]icon[/code] 是一个 [Dictionary]，包含指向资源的 [code]path[/code] 字符串，
## 或者 [code]source_id[/code] [int] 和 [code]coord[/code] [Vector2i]。
func set_terrain(ts: TileSet, index: int, name: String, color: Color, type: int, categories: Array = [], icon: Dictionary = {valid = false}) -> bool:
	if !ts or name.is_empty() or index < 0 or type < 0 or type == TerrainType.DECORATION or type >= TerrainType.MAX:
		return false
	
	var ts_meta := _get_terrain_meta(ts)
	if index >= ts_meta.terrains.size():
		return false
	
	if type == TerrainType.CATEGORY and !categories.is_empty():
		return false
	for c in categories:
		if c < 0 or c == index or c >= ts_meta.terrains.size() or ts_meta.terrains[c][2] != TerrainType.CATEGORY:
			return false
	
	var icon_valid = icon.get("valid", "true")
	if icon_valid:
		match icon:
			{}, {"path"}, {"source_id", "coord"}: pass
			_: return false
	
	if type != TerrainType.CATEGORY:
		for t in ts_meta.terrains:
			t[3].erase(index)
	
	ts_meta.terrains[index] = [name, color, type, categories, icon]
	_set_terrain_meta(ts, ts_meta)
	
	_clear_invalid_peering_types(ts)
	_purge_cache(ts)
	return true


## 交换 [TileSet] 中索引为 [code]index1[/code] 和 [code]index2[/code] 的地形。
func swap_terrains(ts: TileSet, index1: int, index2: int) -> bool:
	if !ts or index1 < 0 or index2 < 0 or index1 == index2:
		return false
	
	var ts_meta := _get_terrain_meta(ts)
	if index1 >= ts_meta.terrains.size() or index2 >= ts_meta.terrains.size():
		return false
	
	for t in ts_meta.terrains:
		var has1 = t[3].has(index1)
		var has2 = t[3].has(index2)
		
		if has1 and !has2:
			t[3].erase(index1)
			t[3].push_back(index2)
		elif has2 and !has1:
			t[3].erase(index2)
			t[3].push_back(index1)
	
	for s in ts.get_source_count():
		var source := ts.get_source(ts.get_source_id(s)) as TileSetAtlasSource
		if !source:
			continue
		for t in source.get_tiles_count():
			var coord := source.get_tile_id(t)
			for a in source.get_alternative_tiles_count(coord):
				var alternate := source.get_alternative_tile_id(coord, a)
				var td := source.get_tile_data(coord, alternate)
				
				var td_meta := _get_tile_meta(td)
				if td_meta.type == TileCategory.NON_TERRAIN:
					continue
				
				if td_meta.type == index1:
					td_meta.type = index2
				elif td_meta.type == index2:
					td_meta.type = index1
				
				for peering in td_meta.keys():
					if !(peering is int):
						continue
					
					var fixed_peering = []
					for p in td_meta[peering]:
						if p == index1:
							fixed_peering.append(index2)
						elif p == index2:
							fixed_peering.append(index1)
						else:
							fixed_peering.append(p)
					td_meta[peering] = fixed_peering
				
				_set_tile_meta(ts, td, td_meta)
	
	var temp = ts_meta.terrains[index1]
	ts_meta.terrains[index1] = ts_meta.terrains[index2]
	ts_meta.terrains[index2] = temp
	_set_terrain_meta(ts, ts_meta)
	
	_purge_cache(ts)
	return true


# Terrain tile data

## 对于 [TileSet] 中由 [TileData] 指定的瓦片，将其关联的地形设置为 [code]type[/code]，
## 这是一个现有地形的索引。成功时返回 [code]true[/code]。
func set_tile_terrain_type(ts: TileSet, td: TileData, type: int) -> bool:
	if !ts or !td or type < TileCategory.NON_TERRAIN:
		return false
	
	var td_meta = _get_tile_meta(td)
	td_meta.type = type
	if type == TileCategory.NON_TERRAIN:
		td_meta = null
	_set_tile_meta(ts, td, td_meta)
	
	_clear_invalid_peering_types(ts)
	_purge_cache(ts)
	return true


## 返回由 [TileData] 指定的瓦片关联的地形类型。如果瓦片没有关联地形则返回 -1。
func get_tile_terrain_type(td: TileData) -> int:
	if !td:
		return TileCategory.ERROR
	var td_meta := _get_tile_meta(td)
	return td_meta.type


## 对于 [TileSet] [code]ts[/code] 中由 [TileData] [code]td[/code] 表示的瓦片，
## 设置 [enum SymmetryType] [code]type[/code]。这控制瓦片在放置时如何旋转/镜像。
func set_tile_symmetry_type(ts: TileSet, td: TileData, type: int) -> bool:
	if !ts or !td or type < SymmetryType.NONE or type > SymmetryType.ALL:
		return false
	
	var td_meta := _get_tile_meta(td)
	if td_meta.type == TileCategory.NON_TERRAIN:
		return false
	
	td_meta.symmetry = type
	_set_tile_meta(ts, td, td_meta)
	_purge_cache(ts)
	return true


## 对于瓦片 [code]td[/code]，返回该瓦片使用的 [enum SymmetryType]。
func get_tile_symmetry_type(td: TileData) -> int:
	if !td:
		return SymmetryType.NONE
	
	var td_meta := _get_tile_meta(td)
	return td_meta.get("symmetry", SymmetryType.NONE)


## 返回 [TileSet] [code]ts[/code] 中指定地形 [code]type[/code] 包含的所有 [TileData] 瓦片的数组。
func get_tiles_in_terrain(ts: TileSet, type: int) -> Array[TileData]:
	var result:Array[TileData] = []
	if !ts or type < TileCategory.EMPTY:
		return result
	
	var cache := _get_cache(ts)
	if type > cache.size():
		return result
	
	var tiles = cache[type]
	if !tiles:
		return result
	for c in tiles:
		if c[0] < 0:
			continue
		var source := ts.get_source(c[0]) as TileSetAtlasSource
		var td := source.get_tile_data(c[1], c[2])
		result.push_back(td)
	
	return result


## 返回一个 [Array]，包含 [Dictionary] 项，每个项都包含有关 [TileSet] [code]ts[/code] 中
## 指定地形 [code]type[/code] 包含的每个瓦片的信息。每个 Dictionary 项包括
## [TileSetAtlasSource] [code]source[/code]、[TileData] [code]td[/code]、
## [Vector2i] [code]coord[/code] 和 [int] [code]alt_id[/code]。
func get_tile_sources_in_terrain(ts: TileSet, type: int) -> Array[Dictionary]:
	var result:Array[Dictionary] = []
	
	var cache := _get_cache(ts)
	var tiles = cache[type]
	if !tiles:
		return result
	for c in tiles:
		if c[0] < 0:
			continue
		var source := ts.get_source(c[0]) as TileSetAtlasSource
		if not source:
			continue
		var td := source.get_tile_data(c[1], c[2])
		result.push_back({
			source = source,
			td = td,
			coord = c[1],
			alt_id = c[2]
		})
	
	return result


## 对于 [TileSet] 的瓦片（由 [TileData] 指定），添加地形 [code]type[/code]
## （一个地形的索引）以在方向 [code]peering[/code]（类型为 [enum TileSet.CellNeighbor]）上匹配此瓦片。
## 成功时返回 [code]true[/code]。
func add_tile_peering_type(ts: TileSet, td: TileData, peering: int, type: int) -> bool:
	if !ts or !td or peering < 0 or peering > 15 or type < TileCategory.EMPTY:
		return false
	
	var ts_meta := _get_terrain_meta(ts)
	var td_meta := _get_tile_meta(td)
	if td_meta.type < TileCategory.EMPTY or td_meta.type >= ts_meta.terrains.size():
		return false
	
	if !td_meta.has(peering):
		td_meta[peering] = [type]
	elif !td_meta[peering].has(type):
		td_meta[peering].append(type)
	else:
		return false
	_set_tile_meta(ts, td, td_meta)
	_purge_cache(ts)
	return true


## 对于 [TileSet] 的瓦片（由 [TileData] 指定），从方向 [code]peering[/code]
## （类型为 [enum TileSet.CellNeighbor]）的匹配中移除地形 [code]type[/code]。
## 成功时返回 [code]true[/code]。
func remove_tile_peering_type(ts: TileSet, td: TileData, peering: int, type: int) -> bool:
	if !ts or !td or peering < 0 or peering > 15 or type < TileCategory.EMPTY:
		return false
	
	var td_meta := _get_tile_meta(td)
	if !td_meta.has(peering):
		return false
	if !td_meta[peering].has(type):
		return false
	td_meta[peering].erase(type)
	if td_meta[peering].is_empty():
		td_meta.erase(peering)
	_set_tile_meta(ts, td, td_meta)
	_purge_cache(ts)
	return true


## 对于由 [TileData] 指定的瓦片，返回设置了地形匹配的对等方向的 [Array]。
## 这些将是 [enum TileSet.CellNeighbor] 类型。
func tile_peering_keys(td: TileData) -> Array:
	if !td:
		return []
	
	var td_meta := _get_tile_meta(td)
	var result := []
	for k in td_meta:
		if k is int:
			result.append(k)
	return result


## 对于由 [TileData] 指定的瓦片，返回在方向 [code]peering[/code]
## （应为 [enum TileSet.CellNeighbor] 类型）上匹配的地形 [Array]。
func tile_peering_types(td: TileData, peering: int) -> Array:
	if !td or peering < 0 or peering > 15:
		return []
	
	var td_meta := _get_tile_meta(td)
	return td_meta[peering].duplicate() if td_meta.has(peering) else []


## 对于由 [TileData] 指定的瓦片，返回指定地形类型 [code]type[/code] 的对等方向 [Array]。
func tile_peering_for_type(td: TileData, type: int) -> Array:
	if !td:
		return []
	
	var td_meta := _get_tile_meta(td)
	var result := []
	var sides := tile_peering_keys(td)
	for side in sides:
		if td_meta[side].has(type):
			result.push_back(side)
	
	result.sort()
	return result


# Painting

## 将地形 [code]type[/code] 应用于 [TileMapLayer] 的 [Vector2i] [code]coord[/code]。
## 如果成功则返回 [code]true[/code]。使用 [method set_cells] 一次更改多个瓦片。
## [br][br]
## 使用地形类型 -1 来擦除单元格。
func set_cell(tm: TileMapLayer, coord: Vector2i, type: int) -> bool:
	if !tm or !tm.tile_set or type < TileCategory.EMPTY:
		return false
	
	if type == TileCategory.EMPTY:
		tm.erase_cell(coord)
		return true
	
	var cache := _get_cache(tm.tile_set)
	if type >= cache.size():
		return false
	
	if cache[type].is_empty():
		return false
	
	var tile = cache[type].front()
	tm.set_cell(coord, tile[0], tile[1], tile[2])
	return true


## 将地形 [code]type[/code] 应用于 [TileMapLayer] 的 [Vector2i] [code]coords[/code]。
## 如果成功则返回 [code]true[/code]。
## [br][br]
## 注意，这不会导致地形求解器运行，所以这只是在给定位置放置一个任意地形相关的瓦片。
## 要运行求解器，你必须设置所需的单元格，然后调用 [method update_terrain_cell]、
## [method update_terrain_cels] 或 [method update_terrain_area]。
## [br][br]
## 如果你想提前准备瓦片的更改，可以使用 [method create_terrain_changeset] 和相关函数。
## [br][br]
## 使用地形类型 -1 来擦除单元格。
func set_cells(tm: TileMapLayer, coords: Array, type: int) -> bool:
	if !tm or !tm.tile_set or type < TileCategory.EMPTY:
		return false
	
	if type == TileCategory.EMPTY:
		for c in coords:
			tm.erase_cell(c)
		return true
	
	var cache := _get_cache(tm.tile_set)
	if type >= cache.size():
		return false
	
	if cache[type].is_empty():
		return false
	
	var tile = cache[type].front()
	for c in coords:
		tm.set_cell(c, tile[0], tile[1], tile[2])
	return true


## 仅当在此地形中有具有匹配对等边集合的瓦片时，用提供的地形 [code]type[/code] 中的新瓦片
## 替换 [TileMapLayer] 的 [Vector2i] [code]coord[/code] 上的现有瓦片。
## 如果有任何瓦片被更改则返回 [code]true[/code]。使用 [method replace_cells] 一次替换多个瓦片。
func replace_cell(tm: TileMapLayer, coord: Vector2i, type: int) -> bool:
	if !tm or !tm.tile_set or type < 0:
		return false
	
	var cache := _get_cache(tm.tile_set)
	if type >= cache.size():
		return false
	
	if cache[type].is_empty():
		return false
	
	var td = tm.get_cell_tile_data(coord)
	if !td:
		return false
	
	var ts_meta := _get_terrain_meta(tm.tile_set)
	var categories = ts_meta.terrains[type][3]
	var check_types = [type] + categories
	
	for check_type in check_types:
		var placed_peering = tile_peering_for_type(td, check_type)
		for pt in get_tiles_in_terrain(tm.tile_set, type):
			var check_peering := tile_peering_for_type(pt, check_type)
			if placed_peering == check_peering:
				var tile = cache[type].front()
				tm.set_cell(coord, tile[0], tile[1], tile[2])
				return true
	
	return false


## 仅当在此地形中有具有匹配对等边集合的瓦片时，用提供的地形 [code]type[/code] 中的新瓦片
## 替换 [TileMapLayer] 的 [Vector2i] [code]coords[/code] 上的现有瓦片。
## 如果有任何瓦片被更改则返回 [code]true[/code]。
func replace_cells(tm: TileMapLayer, coords: Array, type: int) -> bool:
	if !tm or !tm.tile_set or type < 0:
		return false
	
	var cache := _get_cache(tm.tile_set)
	if type >= cache.size():
		return false
	
	if cache[type].is_empty():
		return false
	
	var ts_meta := _get_terrain_meta(tm.tile_set)
	var categories = ts_meta.terrains[type][3]
	var check_types = [type] + categories
	
	var changed = false
	var potential_tiles = get_tiles_in_terrain(tm.tile_set, type)
	for c in coords:
		var found = false
		var td = tm.get_cell_tile_data(c)
		if !td:
			continue
		for check_type in check_types:
			var placed_peering = tile_peering_for_type(td, check_type)
			for pt in potential_tiles:
				var check_peering = tile_peering_for_type(pt, check_type)
				if placed_peering == check_peering:
					var tile = cache[type].front()
					tm.set_cell(c, tile[0], tile[1], tile[2])
					changed = true
					found = true
					break
			
			if found:
				break
	
	return changed


## 返回在 [TileMapLayer] 的指定 [Vector2i] [code]coord[/code] 处检测到的地形类型。
## 如果瓦片无效或不包含与地形关联的瓦片则返回 -1。
func get_cell(tm: TileMapLayer, coord: Vector2i) -> int:
	if !tm or !tm.tile_set:
		return TileCategory.ERROR
	
	if tm.get_cell_source_id(coord) == -1:
		return TileCategory.EMPTY
	
	var t := tm.get_cell_tile_data(coord)
	if !t:
		return TileCategory.NON_TERRAIN
	
	return _get_tile_meta(t).type


## 在 [TileMapLayer] 上为 [code]cells[/code] 参数中给定的 [Vector2i] 坐标运行瓦片求解算法。
## 默认情况下，周围的单元格也会被求解，但可以通过向 [code]and_surrounding_cells[/code] 参数传递 [code]false[/code] 来调整。
## [br][br]
## 另请参见 [method update_terrain_area] 和 [method update_terrain_cell]。
func update_terrain_cells(tm: TileMapLayer, cells: Array, and_surrounding_cells := true) -> void:
	if !tm or !tm.tile_set:
		return
	
	if and_surrounding_cells:
		cells = _widen(tm, cells)
	var needed_cells := _widen(tm, cells)
	
	var types := {}
	for c in needed_cells:
		types[c] = get_cell(tm, c)
	
	var ts_meta := _get_terrain_meta(tm.tile_set)
	var cache := _get_cache(tm.tile_set)
	for c in cells:
		_update_tile_immediate(tm, c, ts_meta, types, cache)


## 在 [TileMapLayer] 上为给定的 [Vector2i] [code]cell[/code] 运行瓦片求解算法。
## 默认情况下，周围的单元格也会被求解，但可以通过向 [code]and_surrounding_cells[/code] 参数传递 [code]false[/code] 来调整。
## 这会调用 [method update_terrain_cells]。
func update_terrain_cell(tm: TileMapLayer, cell: Vector2i, and_surrounding_cells := true) -> void:
	update_terrain_cells(tm, [cell], and_surrounding_cells)


## 在 [TileMapLayer] 上为给定的 [Rect2i] [code]area[/code] 运行瓦片求解算法。
## 默认情况下，周围的单元格也会被求解，但可以通过向 [code]and_surrounding_cells[/code] 参数传递 [code]false[/code] 来调整。
## [br][br]
## 另请参见 [method update_terrain_cells]。
func update_terrain_area(tm: TileMapLayer, area: Rect2i, and_surrounding_cells := true) -> void:
	if !tm or !tm.tile_set:
		return
	
	# Normalize area and extend so tiles cover inclusive space
	area = area.abs()
	area.size += Vector2i.ONE
	
	var edges = []
	for x in range(area.position.x, area.end.x):
		edges.append(Vector2i(x, area.position.y))
		edges.append(Vector2i(x, area.end.y - 1))
	for y in range(area.position.y + 1, area.end.y - 1):
		edges.append(Vector2i(area.position.x, y))
		edges.append(Vector2i(area.end.x - 1, y))
	
	var additional_cells := []
	var needed_cells := _widen_with_exclusion(tm, edges, area)
	
	if and_surrounding_cells:
		additional_cells = needed_cells
		needed_cells = _widen_with_exclusion(tm, needed_cells, area)
	
	var types := {}
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var coord = Vector2i(x, y)
			types[coord] = get_cell(tm, coord)
	for c in needed_cells:
		types[c] = get_cell(tm, c)
	
	var ts_meta := _get_terrain_meta(tm.tile_set)
	var cache := _get_cache(tm.tile_set)
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var coord := Vector2i(x, y)
			_update_tile_immediate(tm, coord, ts_meta, types, cache)
	for c in additional_cells:
		_update_tile_immediate(tm, c, ts_meta, types, cache)


## 对于 [TileMapLayer]，创建一个将通过 [WorkerThreadPool] 计算的更改集，
## 这样它不会延迟处理当前帧或影响帧率。
## [br][br]
## [code]paint[/code] 参数必须是一个 [Dictionary]，其键为表示地图坐标的 [Vector2i] 类型，
## 值为表示地形类型的整数。
## [br][br]
## 返回一个包含内部细节的 [Dictionary]。另请参见 [method is_terrain_changeset_ready]、
## [method apply_terrain_changeset] 和 [method wait_for_terrain_changeset]。
func create_terrain_changeset(tm: TileMapLayer, paint: Dictionary) -> Dictionary:
	# Force cache rebuild if required
	var _cache := _get_cache(tm.tile_set)
	
	var cells := paint.keys()
	var needed_cells := _widen(tm, cells)
	
	var types := {}
	for c in needed_cells:
		types[c] = paint[c] if paint.has(c) else get_cell(tm, c)
	
	var placements := []
	placements.resize(cells.size())
	
	var ts_meta := _get_terrain_meta(tm.tile_set)
	var work := func(n: int):
		placements[n] = _update_tile_deferred(tm, cells[n], ts_meta, types, _cache)
	
	return {
		"valid": true,
		"tilemap": tm,
		"cells": cells,
		"placements": placements,
		"group_id": WorkerThreadPool.add_group_task(work, cells.size(), -1, false, "BetterTerrain")
	}


## 如果由 [method create_terrain_changeset] 创建的更改集已完成线程计算并准备好由 [method apply_terrain_changeset] 应用，
## 则返回 [code]true[/code]。另请参见 [method wait_for_terrain_changeset]。
func is_terrain_changeset_ready(change: Dictionary) -> bool:
	if !change.has("group_id"):
		return false
	
	return WorkerThreadPool.is_group_task_completed(change.group_id)


## 阻塞直到由 [method create_terrain_changeset] 创建的更改集完成。
## 这在节点被移除但仍等待线程时清理线程工作时很有用。
## [br][br]
## 使用示例：
## [codeblock]
## func _exit_tree():
##     if changeset.valid:
##         BetterTerrain.wait_for_terrain_changeset(changeset)
## [/codeblock]
func wait_for_terrain_changeset(change: Dictionary) -> void:
	if change.has("group_id"):
		WorkerThreadPool.wait_for_group_task_completion(change.group_id)


## 一旦通过 [method is_terrain_changeset_ready] 确认，就应用由 [method create_terrain_changeset] 创建的更改集中的更改。
## 更改将应用于初始化更改集的 [TileMapLayer]。
## [br][br]
## 已完成的更改集可以多次应用，并且一旦计算完成就可以根据需要存储。
func apply_terrain_changeset(change: Dictionary) -> void:
	for n in change.cells.size():
		var placement = change.placements[n]
		if placement:
			change.tilemap.set_cell(change.cells[n], placement[0], placement[1], placement[2])
