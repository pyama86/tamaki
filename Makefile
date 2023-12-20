IMAGE_NAME = "ghcr.io/pyama86/tamaki:latest"
build:
	docker build -t $(IMAGE_NAME) .
