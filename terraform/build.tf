# TODO
# - [ ] change the file in s3://codepen-swarm/prod/swarm_env.sh to point to prod instead of stage 
# - [ ] swap the eips out for the real deal
# - [x] nlb not connecting (fixed https://forums.aws.amazon.com/thread.jspa?threadID=263245)

variable "company_name" {
  default = "codepen"
}

locals {
  name_prefix = "${var.company_name}_terraform"
}

variable "vpc" {
  default = "vpc-2c339249"
}

variable "private_subnets" {
  type = "list"

  # projects_a, projects_b
  default = ["subnet-5f87fd29", "subnet-57f9db33"]
}

variable "public_subnets" {
  type = "list"

  # public_a, public_b
  default = ["subnet-b2efa4c4", "subnet-ff43709b"]
}

variable "ubuntu_ami" {
  # ubuntu 16.04
  default = "ami-4e79ed36"
}

locals {
  dashed_name = "${replace(local.name_prefix, "_", "-")}"
}

locals {
  default_tags = {
    Name        = "${local.name_prefix}"
    Environment = "production"
  }
}

resource "aws_lb" "load_balancer" {
  name               = "${local.dashed_name}"
  internal           = false
  load_balancer_type = "application"

  subnet_mapping {
    subnet_id = "${var.public_subnets[0]}"
  }

  subnet_mapping {
    subnet_id = "${var.public_subnets[1]}"
  }

  enable_deletion_protection = false

  tags = "${local.default_tags}"
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = "${aws_lb.load_balancer.arn}"
  port              = "80"
  protocol          = "TCP"

  default_action {
    target_group_arn = "${aws_lb_target_group.target_group.arn}"
    type             = "forward"
  }
}

resource "aws_autoscaling_group" "asg" {
  name                 = "${local.name_prefix}_01"
  launch_configuration = "${aws_launch_configuration.as_conf.name}"
  min_size             = 0
  max_size             = 1
  desired_capacity     = 1
  vpc_zone_identifier  = "${var.private_subnets}"
  health_check_type    = "EC2"
  default_cooldown     = 30
  target_group_arns    = ["${aws_lb_target_group.target_group.id}"]

  tags = [
    {
      key                 = "Name"
      value               = "${local.name_prefix}_01"
      propagate_at_launch = true
    },
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_launch_configuration" "as_conf" {
  name_prefix          = "${local.name_prefix}-"
  image_id             = "${var.ubuntu_ami}"
  instance_type        = "t2.small"
  key_name             = "prod_network"
  security_groups      = ["${aws_security_group.apptoto.id}"]
  iam_instance_profile = "${aws_iam_instance_profile.instance_profile.id}"

  root_block_device {
    volume_size           = "20"
    volume_type           = "gp2"
    delete_on_termination = true
  }

  user_data = <<EOF
${file("./user_data.sh")}
echo 'done with user data!'
  EOF

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "target_group" {
  name                 = "${local.dashed_name}"
  port                 = 8888
  protocol             = "TCP"
  vpc_id               = "${var.vpc}"
  deregistration_delay = 60

  tags = "${local.default_tags}"
}

resource "aws_security_group" "apptoto" {
  name        = "${local.name_prefix}"
  description = "allows inbound from everywhere"
  vpc_id      = "${var.vpc}"

  ingress {
    from_port   = 8888
    to_port     = 8888
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "http"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "http"
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "ssh"
  }

  # https://www.digitalocean.com/community/tutorials/how-to-configure-the-linux-firewall-for-docker-swarm-on-ubuntu-16-04
  ingress {
    from_port   = 2376
    to_port     = 2376
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "docker from client"
  }

  ingress {
    from_port   = 7946
    to_port     = 7946
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "docker tcp between nodes"
  }

  ingress {
    from_port   = 7946
    to_port     = 7946
    protocol    = "udp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "docker udp between nodes"
  }

  ingress {
    from_port   = 4789
    to_port     = 4789
    protocol    = "udp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "overlay network traffic"
  }

  # everything can leave
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = "${local.default_tags}"
}

locals {
  secrets_bucket_name = "${var.company_name}-supersecret"
}

resource "aws_s3_bucket" "secrets_bucket" {
  bucket = "${local.secrets_bucket_name}"
  acl    = "private"

  tags {
    Name = "${local.name_prefix}"
  }
}

data "aws_iam_policy_document" "secrets_bucket_policy" {
  statement {
    sid = "1"

    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["${aws_s3_bucket.secrets_bucket.arn}"]
  }

  statement {
    sid = "2"

    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.secrets_bucket.arn}/*"]
  }
}

resource "aws_iam_policy" "bucket_access_policy" {
  name        = "CodePenApptotoSecrets"
  path        = "/"
  description = "secrets for the swarm env"

  policy = "${data.aws_iam_policy_document.secrets_bucket_policy.json}"
}

resource "aws_iam_role_policy_attachment" "bucket_access_policy_attachment" {
  role       = "${aws_iam_role.role.name}"
  policy_arn = "${aws_iam_policy.bucket_access_policy.arn}"
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "role" {
  name = "${local.name_prefix}"
  path = "/"

  assume_role_policy = "${data.aws_iam_policy_document.assume_role_policy.json}"
}

resource "aws_iam_instance_profile" "instance_profile" {
  name = "${local.name_prefix}"
  role = "${aws_iam_role.role.name}"
}

resource "aws_s3_bucket_object" "secretes_object" {
  bucket = "${local.secrets_bucket_name}"
  key    = "secrets.sh"
  source = "secrets.sh"
  etag   = "${md5(file("secrets.sh"))}"
}
