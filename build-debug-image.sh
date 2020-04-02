#!/usr/bin/env bash
#
# Copyright 2019-2020 by Vegard IT GmbH, Germany, https://vegardit.com
# SPDX-License-Identifier: Apache-2.0
#
# @author Sebastian Thomschke, Vegard IT GmbH
#
# https://github.com/vegardit/docker-openldap
#

bash "$(dirname "$0")/build-image.sh" --build-arg DEBUG_BUILD=1
