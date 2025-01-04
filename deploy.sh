#!/bin/bash
ansible-playbook -i ansible/hosts.ini ansible/deploy.yml --ask-become-pass