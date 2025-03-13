FROM amazon/aws-cli:latest

ARG DETECTED_TAG=main

# Install dependencies
RUN yum install -y curl jq bash git \
    && git clone https://github.com/jambonz/ec2-eip-allocator.git \
    && cd ec2-eip-allocator \
    && git fetch --tags \
    && echo "Checking out tag: ${DETECTED_TAG}" \
    && git checkout ${DETECTED_TAG} \
    && cp assign-eip.sh /usr/local/bin/ \
    && chmod +x /usr/local/bin/assign-eip.sh

# Set the script as the entrypoint
ENTRYPOINT ["/usr/local/bin/assign-eip.sh"]
