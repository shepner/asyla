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

#[Getting Started with Plotly in Python](https://plot.ly/python/getting-started/)
RUN pip3 install plotly
ARG export NODE_OPTIONS=--max-old-space-size=4096
RUN jupyter labextension install @jupyter-widgets/jupyterlab-manager@1.0 --no-build
RUN jupyter labextension install jupyterlab-plotly@1.2.0 --no-build
RUN jupyter labextension install plotlywidget@1.2.0 --no-build
RUN jupyter labextension install jupyterlab-chart-editor@1.2 --no-build
ARG unset NODE_OPTIONS
RUN jupyter lab build


