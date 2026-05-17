variable "name_prefix" {
  type = string
}

variable "ami_id" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "t3.nano"
}

variable "key_name" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "sg_id" {
  type = string
}
