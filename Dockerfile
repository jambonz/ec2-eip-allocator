FROM amazon/aws-cli:latest

# Install dependencies
RUN yum install -y curl jq bash

# Copy the modified script
COPY assign-eip.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/assign-eip.sh

# Set the script as the entrypoint
ENTRYPOINT ["/usr/local/bin/assign-eip.sh"]
