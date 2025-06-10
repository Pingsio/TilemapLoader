extends CharacterBody2D

signal player_move(pos)

var speed:float = 300.0  # 设置一个合适的移动速度

@onready var anim = $AnimatedSprite2D

var direction:Vector2
var facing_right:bool = true  # 记录玩家朝向

func _ready():
	pass
	

func _physics_process(_delta):
	direction = Input.get_vector("a", "d", "w", "s")
	if direction == Vector2.ZERO:  #如果玩家没有移动操作
		velocity = Vector2.ZERO
		anim.play("idle")  # 播放站立动画
	else:  #如果玩家有移动操作
		velocity = direction * speed
		anim.play("run")  # 播放跑步动画
		
		# 根据水平移动方向更新朝向
		if direction.x != 0:
			facing_right = direction.x > 0
			# 根据朝向翻转精灵
			anim.flip_h = !facing_right
	
	move_and_slide()
	emit_signal("player_move", position)  # 发送移动信号
	

func _input(event: InputEvent) -> void:
	if event.is_action_released("["):
		$Camera2D.zoom += Vector2(0.5,0.5)
	if event.is_action_released("]"):
		$Camera2D.zoom -= Vector2(0.5,0.5)
