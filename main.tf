terraform {
  backend "s3" {}
}

variable "DOMAIN" {}

variable "NAME" {}

provider "aws" {}

resource "aws_s3_bucket" "fd_bucket" {
  bucket        = "${var.DOMAIN}"
  force_destroy = true

  tags = {
    Name = "${var.NAME}"
  }

  website {
    index_document = "index.html"
    error_document = "index.html"
  }
}

locals {
  files = [
    {
      local = "static/index.html"
      remote = "index.html"
      type = "text/html"
    },
    {
      local = "static/index.js"
      remote = "index.js"
      type = "application/javascript"
    },
    {
      local = "static/index.css"
      remote = "index.css"
      type = "text/css"
    },
  ]
}

resource "aws_s3_bucket_object" "ob_object" {
  count = "${length(local.files)}"
  bucket = "${var.DOMAIN}"
  key = "${lookup(local.files[count.index], "remote")}"
  source = "${lookup(local.files[count.index], "local")}"
  acl = "public-read"
  content_type = "${lookup(local.files[count.index], "type")}"
  etag = "${md5(file("${lookup(local.files[count.index], "local")}"))}"
}

resource "aws_acm_certificate" "fd_certificate" {
  domain_name               = "${var.DOMAIN}"
  subject_alternative_names = ["*.${var.DOMAIN}"]
  validation_method         = "DNS"

  tags = {
    Name = "${var.NAME}"
  }
}

resource "aws_cloudfront_distribution" "fd_distribution" {
  aliases = ["*.${var.DOMAIN}", "${var.DOMAIN}"]
  enabled = true

  default_cache_behavior {
    allowed_methods = ["HEAD", "GET"]
    cached_methods  = ["HEAD", "GET"]
    compress        = false
    default_ttl     = 0

    forwarded_values {
      cookies {
        forward = "none"
      }

      query_string = "false"
    }

    target_origin_id       = "${var.DOMAIN}"
    viewer_protocol_policy = "redirect-to-https"
  }

  origin {
    domain_name = "${aws_s3_bucket.fd_bucket.website_endpoint}"
    origin_id   = "${var.DOMAIN}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1", "TLSv1.1", "TLSv1.2"]
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = "${var.NAME}"
  }

  viewer_certificate {
    acm_certificate_arn = "${aws_acm_certificate.fd_certificate.arn}"
    ssl_support_method  = "sni-only"
  }
}

resource "aws_route53_zone" "fd_zone" {
  name = "${var.DOMAIN}."

  tags = {
    Name = "${var.NAME}"
  }
}

resource "aws_route53_record" "fd_record_root" {
  name    = "${var.DOMAIN}."
  type    = "A"
  zone_id = "${aws_route53_zone.fd_zone.zone_id}"

  alias {
    evaluate_target_health = false
    name                   = "${aws_cloudfront_distribution.fd_distribution.domain_name}"
    zone_id                = "${aws_cloudfront_distribution.fd_distribution.hosted_zone_id}"
  }
}

resource "aws_route53_record" "fd_record_wild" {
  name    = "*.${var.DOMAIN}."
  type    = "A"
  zone_id = "${aws_route53_zone.fd_zone.zone_id}"

  alias {
    evaluate_target_health = false
    name                   = "${aws_cloudfront_distribution.fd_distribution.domain_name}"
    zone_id                = "${aws_cloudfront_distribution.fd_distribution.hosted_zone_id}"
  }
}

resource "aws_route53_record" "fd_record_validation" {
  count   = "${length(aws_acm_certificate.fd_certificate.domain_validation_options)}"
  name    = "${lookup(aws_acm_certificate.fd_certificate.domain_validation_options[count.index], "resource_record_name")}"
  records = ["${lookup(aws_acm_certificate.fd_certificate.domain_validation_options[count.index], "resource_record_value")}"]
  ttl     = 60
  type    = "${lookup(aws_acm_certificate.fd_certificate.domain_validation_options[count.index], "resource_record_type")}"
  zone_id = "${aws_route53_zone.fd_zone.zone_id}"
}

resource "aws_acm_certificate_validation" "fd_validation" {
  certificate_arn         = "${aws_acm_certificate.fd_certificate.arn}"
  validation_record_fqdns = aws_route53_record.fd_record_validation.*.fqdn
}
