terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "first-bucket" {
  bucket = var.first-bucket
}

resource "aws_s3_bucket" "second-bucket" {
  bucket = var.second-bucket
}

resource "aws_s3_bucket" "third-bucket" {
  bucket = var.third-bucket
}

data "aws_iam_policy_document" "state-machine" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "state-machine" {
  assume_role_policy = data.aws_iam_policy_document.state-machine.json
}

resource "aws_iam_role_policy_attachment" "execute-lambda" {
  role       = aws_iam_role.state-machine.id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaRole"
}

data "aws_iam_policy_document" "read-from-buckets" {
  statement {
    actions = ["s3:GetObject"]
    effect  = "Allow"

    resources = [
      "arn:aws:s3:::${var.first-bucket}/chunk.txt", "arn:aws:s3:::${var.second-bucket}/chunk.txt"
    ]
  }
}

resource "aws_iam_policy" "read-from-buckets" {
  policy = data.aws_iam_policy_document.read-from-buckets.json
}

resource "aws_iam_role_policy_attachment" "read-from-buckets" {
  role       = aws_iam_role.state-machine.id
  policy_arn = aws_iam_policy.read-from-buckets.arn
}

data "aws_iam_policy_document" "write-to-bucket" {
  statement {
    actions = ["s3:PutObject"]
    effect  = "Allow"

    resources = [
      "arn:aws:s3:::${var.third-bucket}/result.txt"
    ]
  }
}

resource "aws_iam_policy" "write-to-bucket" {
  policy = data.aws_iam_policy_document.write-to-bucket.json
}

resource "aws_iam_role_policy_attachment" "write-to-bucket" {
  role       = aws_iam_role.state-machine.id
  policy_arn = aws_iam_policy.write-to-bucket.arn
}

# Lambda

data "aws_iam_policy_document" "lambda-concat" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda-concat" {
  assume_role_policy = data.aws_iam_policy_document.lambda-concat.json
}

data "archive_file" "lambda-placeholder" {
  type        = "zip"
  output_path = "${path.module}/lambda-placeholder.zip"

  source {
    content  = "exports.handler = async (event) => {};"
    filename = "index.js"
  }
}

resource "aws_lambda_function" "concat" {
  function_name = "concat"
  role          = aws_iam_role.lambda-concat.arn
  runtime       = "nodejs12.x"
  handler       = "index.handler"
  filename      = data.archive_file.lambda-placeholder.output_path

  lifecycle {
    ignore_changes = [filename]
  }
}

# State machine

resource "aws_sfn_state_machine" "state-machine" {
  definition = <<EOF
  {
    "Comment": "Example of a simple state machine",
    "StartAt": "Parallel",
    "States": {
      "Parallel": {
        "Type": "Parallel",
        "Branches": [
          {
            "StartAt": "Read first chunk",
            "States": {
              "Read first chunk": {
                "Type": "Task",
                "End": true,
                "Parameters": {
                  "Bucket": "${aws_s3_bucket.first-bucket.bucket}",
                  "Key": "chunk.txt"
                },
                "Resource": "arn:aws:states:::aws-sdk:s3:getObject",
                "ResultSelector": {
                  "Body.$": "$.Body"
                }
              }
            }
          },
          {
            "StartAt": "Read second chunk",
            "States": {
              "Read second chunk": {
                "Type": "Task",
                "End": true,
                "Parameters": {
                  "Bucket": "${aws_s3_bucket.second-bucket.bucket}",
                  "Key": "chunk.txt"
                },
                "Resource": "arn:aws:states:::aws-sdk:s3:getObject",
                "ResultSelector": {
                  "Body.$": "$.Body"
                }
              }
            }
          }
        ],
        "Next": "Map",
        "ResultPath": "$.Body"
      },
      "Map": {
        "Type": "Pass",
        "Parameters": {
          "tokens.$": "States.Array($.Body[0].Body, $.Body[1].Body, $.Suffix)"
        },
        "Next": "Reduce"
      },
      "Reduce": {
        "Type": "Task",
        "Resource": "arn:aws:states:::lambda:invoke",
        "OutputPath": "$.Payload",
        "Parameters": {
          "Payload.$": "$",
          "FunctionName": "${aws_lambda_function.concat.arn}:$LATEST"
        },
        "Retry": [
          {
            "ErrorEquals": [
              "Lambda.ServiceException",
              "Lambda.AWSLambdaException",
              "Lambda.SdkClientException"
            ],
            "IntervalSeconds": 2,
            "MaxAttempts": 6,
            "BackoffRate": 2
          }
        ],
        "Next": "Write"
      },
      "Write": {
        "Type": "Task",
        "End": true,
        "Parameters": {
          "Body.$": "$",
          "Bucket": "${aws_s3_bucket.third-bucket.bucket}",
          "Key": "result.txt"
        },
        "Resource": "arn:aws:states:::aws-sdk:s3:putObject"
      }
    }
  }
  EOF
  name       = "concat"
  role_arn   = aws_iam_role.state-machine.arn
}