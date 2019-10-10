FROM webdevops/php-apache

ENV LIMESURVEY_GIT_RELEASE 2.05_plus_141123

RUN phpenmod imap 

RUN a2enmod rewrite

COPY 000init.sh /entrypoint.d/000init.sh
RUN chmod +x /entrypoint.d/000init.sh

SHELL [ "/bin/bash", "--login", "-c" ]

VOLUME ["/var/www/html/plugins"]
VOLUME ["/var/www/html/upload"]