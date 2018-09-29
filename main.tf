#~~~~~~~~~~~~~~~~~~~~~~~~
# Backend Configuration
#~~~~~~~~~~~~~~~~~~~~~~~~
terraform {
  required_version = "0.11.7"
}

provider "aws" {
  version = "~> 1.34.0"
  region  = "${var.aws_region}"
}


#~~~~~~
# VPC
#~~~~~~
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name                 = "my-vpc"
  cidr                 = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  azs             = ["eu-west-1a", "eu-west-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.3.0/24", "10.0.4.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
}


#~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Application Load Balancer
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~
resource "aws_lb" "ecs" {
  name               = "ecs-lb"
  internal           = false
  load_balancer_type = "application"

  subnets = ["${module.vpc.public_subnets}"]
}

resource "aws_lb_target_group" "ecs" {
  name        = "ecs-tg"
  protocol    = "HTTP"
  port        = 80
  target_type = "ip"
  vpc_id      = "${module.vpc.vpc_id}"
  
  health_check {
    path                = "/"
    port                = 80
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5   # seconds
    interval            = 10  # seconds
    matcher             = "200" # HTTP status codes
  }
}

resource "aws_lb_listener" "ecs" {
  load_balancer_arn = "${aws_lb.ecs.arn}"
  protocol          = "HTTP"
  port              = 80
  
  default_action {
    type = "forward"
    target_group_arn = "${aws_lb_target_group.ecs.arn}"
  }
}


#~~~~~~~~~~~~~~~~~~~~~~
# ALB: Security Group
#~~~~~~~~~~~~~~~~~~~~~~
resource "aws_security_group" "alb" {
  name        = "ecs-alb-sg"
  vpc_id      = "${module.vpc.vpc_id}"

  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = -1
    cidr_blocks = ["0.0.0.0/0"]
  }
}


#~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# ECS Tasks: Security Group
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~
resource "aws_security_group" "ecs" {
  name        = "ecs-tasks"
  vpc_id      = "${module.vpc.vpc_id}"

  ingress {
    from_port = 1
    to_port = 65535
    protocol = "tcp"
    security_groups = ["${aws_security_group.alb.id}"]
  }

  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = -1
    cidr_blocks = ["0.0.0.0/0"]
  }
}


#~~~~~~~~~~~~~~
# ECS Cluster
#~~~~~~~~~~~~~~
resource "aws_ecs_cluster" "main" {
  name = "ecs-cluster"
}

resource "aws_ecs_task_definition" "app" {
  family = "sample-app"
  network_mode = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu = 256
  memory = 512

  container_definitions = <<DEFINITION
[
  {
    "cpu": 256,
    "memoryReservation": 512,
    "image": "httpd:2.4",
    "name": "sample-app",
    "networkMode": "awsvpc",
    "portMappings": [
      {
        "containerPort": 80,
        "hostPort": 80,
        "protocol": "tcp"
      }
    ],
    "essential": true,
    "entryPoint": [
      "sh",
      "-c"
    ],
    "command": [
      "/bin/sh -c \"echo '<html> <head> <title>Amazon ECS Sample App</title> <style>body {margin-top: 40px; background-color: #333;} </style> </head><body> <div style=color:white;text-align:center> <h1>Amazon ECS Sample App</h1> <h2>Congratulations!</h2> <p>Your application is now running on a container in Amazon ECS.</p> </div></body></html>' >  /usr/local/apache2/htdocs/index.html && httpd-foreground\""
    ]
  }
]
DEFINITION
}

resource "aws_ecs_service" "app" {
  name            = "sample-app"
  cluster         = "${aws_ecs_cluster.main.id}"
  task_definition = "${aws_ecs_task_definition.app.arn}"
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    security_groups  = ["${aws_security_group.ecs.id}"]
    subnets          = ["${module.vpc.private_subnets}"]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = "${aws_lb_target_group.ecs.id}"
    container_name   = "sample-app"
    container_port   = "80"
  }

  depends_on = [
    "aws_lb_listener.ecs",
  ]
}