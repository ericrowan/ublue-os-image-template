# Recipe for standard bluefin image
bluefin:
	@podman build --tag ericrowan/bluefin:41 .

# Recipe for standard bazzite image
bazzite:
	@podman build --build-arg SOURCE_IMAGE=bazzite --build-arg SOURCE_TAG=41 --tag ericrowan/bazzite:41 .

# Recipe for standard aurora image
aurora:
	@podman build --build-arg SOURCE_IMAGE=aurora --build-arg SOURCE_TAG=41 --tag ericrowan/aurora:41 .

# Recipe for your custom image (using bluefin-dx as an example)
custom:
	@podman build --file Containerfile.custom --tag ericrowan/custom-image:41 .