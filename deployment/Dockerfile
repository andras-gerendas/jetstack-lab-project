FROM alpine
RUN apk add --update --no-cache bash inotify-tools nginx curl openssl tcpdump
RUN sed -i 's?^#include /etc/nginx/conf.d/\*\.conf;?include /etc/nginx/conf.d/*.conf;?' /etc/nginx/nginx.conf
RUN sed -i '/http {/,$d' /etc/nginx/nginx.conf
CMD ["nginx", "-g", "daemon off;"]