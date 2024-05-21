provider "aws" {
  region = "sa-east-1"  # sao paulo region
}

variable "server_port" {
  description = "The port the server will use for HTTP requests"
  type        = number
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "alb" {
  name = "test-backend-alb"
  # Allow inbound HTTP requests
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow inbound HTTPS requests
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound requests
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "instance" {
  name = "test-backend-instance"
  # Allow inbound HTTP requests
  ingress {
    from_port   = var.server_port
    to_port     = var.server_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound requests
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_autoscaling_group" "backend" {
  launch_configuration = aws_launch_configuration.backend.name
  vpc_zone_identifier  = data.aws_subnets.default.ids
  target_group_arns = [aws_lb_target_group.asg.arn]
  health_check_type = "ELB"
  min_size = 1
  max_size = 2

  tag {
    key                 = "Name"
    value               = "test-backend"
    propagate_at_launch = true
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 90
      instance_warmup        = 300
    }

    triggers = ["launch_configuration"]
  }
}

resource "aws_launch_configuration" "backend" {
  image_id        = "" #image id from aws aws_launch_configuration
  instance_type   = "t2.micro" #any type of instance
  security_groups = [aws_security_group.instance.id]

  user_data = file("../commands.sh") #directory of commands file
  # Required when using a launch configuration with an ASG.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb" "backend" {
  name               = "test-backend"
  load_balancer_type = "application"
  subnets            = data.aws_subnets.default.ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.backend.arn
  port              = 80
  protocol          = "HTTP"

  # By default, return a simple 404 page
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

resource "aws_lb_target_group" "asg" {
  name     = "test-backend"
  port     = var.server_port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
}

data "aws_route53_zone" "selected" {
  name         = "" #your domain name from route53
  private_zone = false
}

#update dns name of alb in route53
resource "aws_route53_record" "domain-record1" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = "" #name of domain/subdomain
  type    = "A"

  alias {
    name                   = aws_lb.backend.dns_name
    zone_id                = aws_lb.backend.zone_id
    evaluate_target_health = true
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.backend.arn  # Your ALB's ARN
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06" # Choose an appropriate SSL policy

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg.arn  # Your target group ARN
  }

  certificate_arn = ""  # your region certificate's ARN
}

output "alb_dns_name" {
  value       = aws_lb.backend.dns_name
  description = "The domain name of the load balancer"
}