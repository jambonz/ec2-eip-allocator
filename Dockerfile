FROM amazon/aws-cli:2.7.7

ARG DETECTED_TAG=main

RUN  yum install -y curl jq
COPY docker-entrypoint.sh .
RUN chmod +x docker-entrypoint.sh
ENTRYPOINT ["./docker-entrypoint.sh"]