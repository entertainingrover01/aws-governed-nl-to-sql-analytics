# S3 static website hosting for the demo widget (frontend/).
#
# The bucket is publicly readable so the widget can be opened directly from
# its S3 website endpoint. That is a deliberate demo trade-off: for a real
# deployment, serve the widget through CloudFront with Origin Access
# Control instead. The widget contains no secrets — only the public API URL.
resource "aws_s3_bucket" "widget" {
  bucket        = "${var.project}-${var.environment}-${data.aws_caller_identity.current.account_id}-widget"
  force_destroy = true # demo convenience: `terraform destroy` removes objects too
}

resource "aws_s3_bucket_website_configuration" "widget" {
  bucket = aws_s3_bucket.widget.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "widget" {
  bucket = aws_s3_bucket.widget.id

  block_public_acls       = true
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "widget_public_read" {
  bucket = aws_s3_bucket.widget.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.widget.arn}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.widget]
}
