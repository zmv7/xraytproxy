#!/bin/bash

if [[ $1 == "status" ]]; then
    if systemctl is-active --quiet xraytproxy.service; then
        echo "XTP:1"
    else
        echo "XTP:0"
    fi
elif [[ $1 == "toggle" ]]; then
    if systemctl is-active --quiet xraytproxy.service; then
        systemctl stop xraytproxy
    else
        systemctl start xraytproxy
    fi
fi
