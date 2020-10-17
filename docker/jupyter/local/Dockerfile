# Local version of Jupyter

# https://github.com/jupyter/docker-stacks/tree/master/scipy-notebook
ARG BASE_CONTAINER=jupyter/scipy-notebook
FROM $BASE_CONTAINER

# Local config changes for the JupyterLab container go here
LABEL maintainer="Stephen Hepner <shepner@asyla.org>"

RUN \
  pip3 install \
    boto3 \
    pyyaml \
    fabric

RUN \
  pip3 install \
    flask \
    huey \
    micawber \
    peewee \
    redis \
    markdown \
    flask_peewee \
    beautifulsoup4

# [ruamel.yaml](https://yaml.readthedocs.io/en/latest/install.html)
RUN \
  pip3 install \
    setuptools \
    ruamel.yaml

# https://pypi.org/project/plotly/
RUN pip3 install "ipywidgets==7.5"
# Basic JupyterLab renderer support
RUN jupyter labextension install jupyterlab-plotly@4.11.0
# OPTIONAL: Jupyter widgets extension for FigureWidget support
RUN jupyter labextension install @jupyter-widgets/jupyterlab-manager plotlywidget@4.11.0

#https://github.com/jupyter/jupyter/wiki/Jupyter-kernels
#https://vatlab.github.io/sos-docs/
#https://github.com/vatlab/SOS
RUN \
  pip3 install \
    sos \
    sos-notebook \
  && python3 -m sos_notebook.install \
  && jupyter labextension install transient-display-data --no-build \
  && jupyter labextension install jupyterlab-sos --no-build \
  && jupyter lab build







# Run this last as it takes a while
RUN jupyter lab build


