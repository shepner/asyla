# Local version of Jupyter

# https://github.com/jupyter/docker-stacks/tree/master/scipy-notebook
ARG BASE_CONTAINER=jupyter/scipy-notebook
FROM $BASE_CONTAINER

# Local config changes for the JupyterLab container go here
LABEL maintainer="Stephen Hepner <shepner@asyla.org>"

RUN pip3 install boto3 pyyaml fabric

RUN pip3 install flask huey micawber peewee redis markdown flask_peewee beautifulsoup4

# [ruamel.yaml](https://yaml.readthedocs.io/en/latest/install.html)
RUN pip3 install setuptools ruamel.yaml

