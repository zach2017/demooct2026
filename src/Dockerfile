# Placeholders are replaced by the Jenkins "hello" job using the
# HELLO_IMAGE / HELLO_IMAGE_TAG values from the jenkins-global-env ConfigMap.
FROM __HELLO_IMAGE__:__HELLO_IMAGE_TAG__

COPY hello.sh /hello.sh
CMD ["/hello.sh"]
