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
RUN \
  pip3 install \
    plotly \
    "ipywidgets==7.5" \
  && jupyter labextension install jupyterlab-plotly@4.11.0  --no-build \
  && jupyter labextension install @jupyter-widgets/jupyterlab-manager plotlywidget@4.11.0  --no-build

#https://github.com/jupyter/jupyter/wiki/Jupyter-kernels
#https://vatlab.github.io/sos-docs/
#https://github.com/vatlab/SOS
RUN \
  pip3 install \
    sos \
    sos-notebook \
  && python3 -m sos_notebook.install \
  && jupyter labextension install transient-display-data --no-build \
  && jupyter labextension install jupyterlab-sos --no-build

#https://github.com/jupyterlab/jupyterlab-toc
RUN jupyter labextension install @jupyterlab/toc --no-build

#themes
#https://github.com/oriolmirosa/jupyterlab_materialdarker
#sudo jupyter labextension install @oriolmirosa/jupyterlab_materialdarker
# https://github.com/telamonian/theme-darcula
#sudo jupyter labextension install @telamonian/theme-darcula
#https://github.com/Rahlir/theme-gruvbox
#RUN jupyter labextension install @rahlir/theme-gruvbox --no-build

# Run this last as it takes a while
RUN jupyter lab build


