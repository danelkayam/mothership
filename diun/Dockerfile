FROM crazymax/diun:latest

RUN apk --update --no-cache add curl

COPY notify.sh /
RUN chmod +x /notify.sh

CMD [ "serve" ]